"""Fails when an addon's TOC interface versions are behind the live WoW clients.

Run:        python CheckTocVersions.py [addon-root]
Self-test:  python CheckTocVersions.py --self-test

The current builds are read from warcraft.wiki.gg's "Public client builds" page, which keeps a
per-client table of the live version, its interface number and its build. The page renders that
table from a template, so the raw wikitext is useless here - the MediaWiki parse API is asked to
expand it instead, and the resulting HTML table is scraped.

A client marks an addon out of date unless the exact interface number of that client appears in
the TOC's list, so "5.5.3 when live is 5.5.4" is enough to make it load with the out-of-date
warning. An addon only cares about the clients it actually ships for, so a live client is only
compared against a TOC that already lists SOME interface with the same major version - MiniCC
targeting only 12.x is not behind on Classic Era, it simply does not support it.

An addon behind a LIVE client fails the build - it is greyed out in the character-select addon
list until the TOC is bumped, which is worth blocking on.

Two things deliberately do not fail. A test-realm build is not a live client, and an addon is
free to wait for a PTR build to go live before adopting it. And an unreachable or restructured
wiki page exits 0 with a note, because whether the build passes must not depend on a third
party site being reachable from the runner.

Note the consequence of failing on live builds: the day Blizzard ships a patch, every addon
that has not been bumped goes red at once, without anyone having changed a line. That is the
intent - the TOC bump is the work the patch created - but it does mean an unrelated change can
be blocked by one.
"""
from __future__ import print_function

import io
import json
import os
import re
import sys

try:
    from urllib.request import Request, urlopen
    from urllib.parse import urlencode
except ImportError:  # Python 2
    from urllib2 import Request, urlopen
    from urllib import urlencode

WIKI_API = "https://warcraft.wiki.gg/api.php"
WIKI_PAGE = "https://warcraft.wiki.gg/wiki/Public_client_builds"
USER_AGENT = "addon-devops CheckTocVersions (+https://github.com/Verubato/addon-devops)"
TIMEOUT = 30

ROW = re.compile(r"<tr>(.*?)</tr>", re.S)
CELL = re.compile(r"<td[^>]*>(.*?)</td>", re.S)
TAG = re.compile(r"<[^>]+>")
# The wiki tags every non-live row with the Test realm icon; nothing else distinguishes a PTR
# row from the live one it shadows.
TEST_ICON = re.compile(r'alt="Test"')
INTERFACE_CODE = re.compile(r"<code>\s*(\d+)\s*</code>")
# The product code Blizzard uses for the client - wow, wowt, wow_classic_era and friends. The
# cell also carries human-readable titles, so the shape of the value is what identifies it.
PRODUCT = re.compile(r'title="(wow[a-z0-9_]*)"')

# ## Interface: 120100, 120007  /  ## Interface-Mists: 50504
TOC_INTERFACE = re.compile(r"^##[ \t]*Interface(-\w+)?[ \t]*:[ \t]*([0-9, \t]+)", re.M | re.I)

# Third party TOCs that ship inside the addon; their interface lines are not ours to bump.
SKIP_DIRS = ("Libs",)


def read(path):
    # utf-8-sig: TOCs are routinely saved with a BOM, which would otherwise glue itself to the
    # first "##" and hide the Interface line from the regex.
    return io.open(path, encoding="utf-8-sig").read()


def text_of(html):
    return TAG.sub("", html).replace("&amp;", "&").strip()


def fetch_builds():
    """Returns the rendered HTML of the wiki's current-builds table."""
    query = urlencode({
        "action": "parse",
        "text": "{{Current builds}}",
        "contentmodel": "wikitext",
        "title": "Public client builds",
        "prop": "text",
        "format": "json",
        "formatversion": "2",
    })
    request = Request(WIKI_API + "?" + query, headers={"User-Agent": USER_AGENT})
    payload = json.loads(urlopen(request, timeout=TIMEOUT).read().decode("utf-8"))
    return payload["parse"]["text"]


def parse_builds(html):
    """Scrapes the current-builds table into a list of client dicts."""
    clients = []

    for row in ROW.findall(html):
        cells = CELL.findall(row)

        # Server, expansion icon, expansion, version, interface, build, date.
        if len(cells) < 7:
            continue

        interface = INTERFACE_CODE.search(cells[4])
        product = PRODUCT.search(cells[0])

        if not interface:
            continue

        clients.append({
            "name": text_of(cells[0]),
            "product": product.group(1) if product else "",
            "expansion": text_of(cells[2]),
            "version": text_of(cells[3]),
            "interface": int(interface.group(1)),
            "build": text_of(cells[5]),
            "date": text_of(cells[6]),
            "live": not TEST_ICON.search(row),
        })

    return clients


def toc_files(src_root):
    for base, dirs, files in os.walk(src_root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if name.lower().endswith(".toc"):
                yield os.path.join(base, name)


def toc_interfaces(text):
    """Every interface number a TOC declares, across all of its Interface directives."""
    values = []
    for _, listed in TOC_INTERFACE.findall(text):
        for value in listed.split(","):
            value = value.strip()
            if value.isdigit():
                values.append(int(value))
    return values


def major(interface):
    """12.0.7 -> 12. The expansion line an interface number belongs to."""
    return interface // 10000


def compare(interfaces, clients):
    """Splits the clients into ones this TOC is behind on and test realms it has not adopted.

    A client is only relevant when the TOC already lists something from the same expansion
    line, which is what stands in for "this addon ships for that client".
    """
    targeted = {major(value) for value in interfaces}
    listed = set(interfaces)

    behind, untested = [], []

    for client in clients:
        if major(client["interface"]) not in targeted:
            continue
        if client["interface"] in listed:
            continue

        if client["live"]:
            behind.append(client)
        # A test realm parked on an older build than the TOC already covers is not news - the
        # alpha client sits on last patch's build for most of a cycle.
        elif client["interface"] > max(same_line(interfaces, client)):
            untested.append(client)

    return behind, untested


def same_line(interfaces, client):
    """The TOC's own interfaces for that client's expansion line, for the message."""
    return [value for value in interfaces if major(value) == major(client["interface"])]


def fail(title, message):
    # ::error:: turns into a red annotation on the run; plain text is enough locally.
    if os.environ.get("GITHUB_ACTIONS"):
        print("::error title=%s::%s" % (title, message))
    else:
        print("  %s" % message)


def report(root, clients):
    src_root = os.path.join(root, "src")
    scan_root = src_root if os.path.isdir(src_root) else root

    print("Live client builds (%s):" % WIKI_PAGE)
    for client in clients:
        if client["live"]:
            print("  %-28s %-42s %-8s %-7d build %-7s %s"
                  % (client["name"], client["expansion"], client["version"],
                     client["interface"], client["build"], client["date"]))

    files = list(toc_files(scan_root))

    if not files:
        print("\nno .toc under %s - nothing to check" % os.path.abspath(scan_root))
        return 0

    stale = 0

    for path in files:
        interfaces = toc_interfaces(read(path))
        relative = os.path.relpath(path, root).replace("\\", "/")

        if not interfaces:
            print("\n%s: no Interface directive" % relative)
            continue

        behind, untested = compare(interfaces, clients)

        print("\n%s: %s" % (relative, ", ".join(str(value) for value in interfaces)))

        for client in behind:
            stale += 1
            mine = ", ".join(str(value) for value in sorted(same_line(interfaces, client), reverse=True))
            fail("%s is out of date" % os.path.basename(path),
                 "%s: %s is on %s and needs %d, but the TOC lists %s for that expansion"
                 % (relative, client["name"], client["version"], client["interface"], mine))

        # Not a warning: an addon is free to wait for a PTR build to go live before adopting it.
        for client in untested:
            print("  test realm not listed: %s is on %s (%d)"
                  % (client["name"], client["version"], client["interface"]))

        if not behind and not untested:
            print("  up to date")

    print("\n%d client version%s behind across %d TOC file%s"
          % (stale, "" if stale == 1 else "s", len(files), "" if len(files) == 1 else "s"))

    return 1 if stale else 0


SELF_TEST_HTML = """
<table><tbody><tr>
<th>Server</th><th colspan="2">Expansion</th><th>Version</th><th>Interface</th><th>Build</th><th>Date</th>
</tr>
<tr>
<td><a title="Retail"><span title="wow">Retail</span></a></td>
<td><span class="icon"><img alt="Midnight" src="/x.png"/></span></td>
<td><a title="Midnight">Midnight</a></td>
<td><a title="12.0.7">12.0.7</a></td>
<td><code>120007</code></td>
<td>68887</td>
<td><span title="2026-07-22">2026-07-22</span>
</td></tr>
<tr>
<td><span title="wowt">Retail <a title="PTR"><span title="wowt">PTR</span></a></span></td>
<td><a title="Test"><img alt="Test" src="/Test-inline.png"/></a></td>
<td><a title="Midnight">Midnight</a></td>
<td><a title="12.1.0">12.1.0</a></td>
<td><code>120100</code></td>
<td>68914</td>
<td><span title="2026-07-23">2026-07-23</span>
</td></tr>
<tr>
<td><a title="Classic"><span title="wow_classic">Classic</span></a></td>
<td><span class="icon"><img alt="Mists" src="/y.png"/></span></td>
<td><a title="Mists of Pandaria Classic">Mists of Pandaria Classic</a></td>
<td><a title="5.5.4">5.5.4</a></td>
<td><code>50504</code></td>
<td>68806</td>
<td><span title="2026-07-17">2026-07-17</span>
</td></tr>
</tbody></table>
"""

SELF_TEST_CASES = [
    # (label, toc text, expected behind, expected test realms not listed)
    ("current retail", "## Interface: 120100, 120007\n", [], []),
    ("behind on retail", "## Interface: 120100, 120005\n", [120007], []),
    ("behind on classic", "## Interface: 120007, 50503\n", [50504], [120100]),
    ("classic only", "## Interface: 50504\n", [], []),
    # 11.x is a line no live client is on any more, so it is nobody's business but the author's.
    ("legacy line only", "## Interface: 110207\n", [], []),
    ("ptr not adopted", "## Interface: 120007\n", [], [120100]),
    ("split directives", "## Interface-Mainline: 120007\n## Interface-Mists: 50503\n", [50504], [120100]),
]


def self_test():
    clients = parse_builds(SELF_TEST_HTML)
    failures = 0

    expected = [("wow", True, 120007), ("wowt", False, 120100), ("wow_classic", True, 50504)]
    actual = [(c["product"], c["live"], c["interface"]) for c in clients]

    if actual != expected:
        failures += 1
        print("FAIL table parse\n  expected %r\n  got      %r" % (expected, actual))

    for label, toc, want_behind, want_untested in SELF_TEST_CASES:
        behind, untested = compare(toc_interfaces(toc), clients)
        got = ([c["interface"] for c in behind], [c["interface"] for c in untested])

        if got != (want_behind, want_untested):
            failures += 1
            print("FAIL %s\n  expected %r\n  got      %r" % (label, (want_behind, want_untested), got))

    print("self-test: %s" % ("passed" if not failures else "%d FAILED" % failures))
    return failures == 0


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    if "--self-test" in argv:
        return 0 if self_test() else 1

    root = argv[1] if len(argv) > 1 else "."

    try:
        clients = parse_builds(fetch_builds())
    except Exception as error:
        print("could not read %s (%s) - skipping" % (WIKI_PAGE, error))
        return 0

    if not clients:
        print("no builds found on %s - the page layout may have changed" % WIKI_PAGE)
        return 0

    return report(root, clients)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
