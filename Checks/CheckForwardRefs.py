"""Flags file-local Lua functions that are referenced before they are declared.

Run:        python CheckForwardRefs.py [path ...]
Self-test:  python CheckForwardRefs.py --self-test

With no path it scans `../../src` relative to this file - i.e. the addon that mounts this repo
as its `build` submodule. Pass paths explicitly to scan anywhere else.

In Lua a name inside a function body binds at COMPILE time. If `local function Foo` appears
later in the file than a body that mentions `Foo`, that body compiled `Foo` as a GLOBAL read,
which is nil at run time - "attempt to call a nil value" the first time the path is hit. The
usual escape hatch is a bare forward declaration (`local Foo` early, `Foo = function() ... end`
later), which this understands and does not flag.

Neither luacheck nor an addon's test suite catches this reliably: luacheck sees the name as an
undefined global, which every addon's .luacheckrc suppresses because addons legitimately read
real WoW globals. Reordering a file is when it matters.

Exits 1 when anything is reported, so it can gate a lint run.
"""
import os
import re
import sys

KEYWORDS = set("""and break do else elseif end false for function goto if in local nil not or
repeat return then true until while self""".split())

DECL_RE = re.compile(r"^(local function (\w+)|function ([\w.:]+))")
SINGLE_LINE_RE = re.compile(r"\bend\s*$")
# Any bare identifier reference, not just a call: a function passed as a value
# (RegisterCallback(NotifyCallbacks)) binds exactly the same way. Skips field access
# (a.Foo / a:Foo) and assignment targets / table-constructor keys (Foo = ...).
REFERENCE_RE = re.compile(r"""(?<![\w.:])([A-Za-z_]\w*)\s*(?!=[^=])(?![\w=])""")

# This repo is mounted as an addon's `build` submodule, so the addon's sources sit alongside it.
# Three levels up from <addon>/build/Checks/CheckForwardRefs.py lands on the addon root.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SRC = os.path.join(_REPO_ROOT, "src")


def strip_noise(line):
    """Drops comments and string contents so they can't look like code."""
    line = re.sub(r"--.*$", "", line)
    line = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(\\.|[^'\\])*'", "''", line)
    return line


def analyse(path):
    """Returns [(line, enclosing_name, referenced_name, declaration_line)]."""
    lines = [strip_noise(l) for l in open(path, encoding="utf-8").read().split("\n")]

    declared = {}   # every top-level local -> index where it becomes visible
    functions = {}  # top-level local FUNCTION -> index of its declaration
    for i, line in enumerate(lines):
        m = re.match(r"^local function (\w+)", line)
        if m:
            declared.setdefault(m.group(1), i)
            functions.setdefault(m.group(1), i)
            continue
        m = re.match(r"^local (\w+)\s*=\s*function", line)
        if m:
            declared.setdefault(m.group(1), i)
            functions.setdefault(m.group(1), i)
            continue
        m = re.match(r"^local ([\w\s,]+?)\s*(=|$)", line)
        if m:
            for name in m.group(1).split(","):
                if name.strip():
                    declared.setdefault(name.strip(), i)

    # Top-level function bodies, as (start, end, name).
    blocks = []
    i = 0
    while i < len(lines):
        m = DECL_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(2) or m.group(3)
        if SINGLE_LINE_RE.search(lines[i]):
            blocks.append((i, i, name))
            i += 1
            continue
        end = i
        while end < len(lines) and lines[end] != "end":
            end += 1
        blocks.append((i, min(end, len(lines) - 1), name))
        i = end + 1

    problems = []
    for start, end, name in blocks:
        for ln in range(start + 1, end + 1):
            for m in REFERENCE_RE.finditer(lines[ln]):
                ref = m.group(1)
                if ref in KEYWORDS or ref not in functions:
                    continue
                if functions[ref] > start and declared.get(ref, sys.maxsize) > start:
                    problems.append((ln + 1, name, ref, functions[ref] + 1))

    # Statements at file scope that call something declared further down.
    covered = set()
    for start, end, _ in blocks:
        covered.update(range(start, end + 1))
    for i, line in enumerate(lines):
        if i in covered:
            continue
        for m in re.finditer(r"(?<![\w.:])([A-Za-z_]\w*)\s*(?=\()", line):
            ref = m.group(1)
            if ref in KEYWORDS or ref not in functions:
                continue
            if functions[ref] > i:
                problems.append((i + 1, "<file scope>", ref, functions[ref] + 1))

    return problems


def scan(roots):
    total = 0
    for root in roots:
        if not os.path.isdir(root):
            print("skipped (no such directory): %s" % root)
            continue
        base = os.path.dirname(os.path.abspath(root))
        for dirpath, _, filenames in os.walk(root):
            if "Libs" in dirpath:
                continue
            for filename in sorted(filenames):
                if not filename.endswith(".lua"):
                    continue
                path = os.path.join(dirpath, filename)
                rel = os.path.relpath(path, base).replace("\\", "/")
                for line, enclosing, ref, decl_line in analyse(path):
                    print("%s:%d  %s references '%s', declared later at line %d"
                          % (rel, line, enclosing, ref, decl_line))
                    total += 1
    print("\n%d forward-reference problem(s)" % total)
    return total


def self_test():
    """Fixtures pinning what must and must not be reported."""
    import tempfile

    cases = [
        ("call of a later local", True,
         "local function Caller()\n\treturn Later()\nend\n\nlocal function Later()\n\treturn 1\nend\n"),
        ("later local passed as a value", True,
         "local function Caller()\n\treturn Register(Later)\nend\n\nlocal function Later()\n\treturn 1\nend\n"),
        ("forward declaration", False,
         "local Later\n\nlocal function Caller()\n\treturn Later()\nend\n\nLater = function()\n\treturn 1\nend\n"),
        ("single-line functions", False,
         "local function A(a, b) return a < b end\nlocal function B(a, b) return a > b end\n"
         "\nlocal function C()\n\treturn A, B\nend\n"),
        ("normal order", False,
         "local function Early()\n\treturn 1\nend\n\nlocal function Caller()\n\treturn Early()\nend\n"),
    ]

    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for label, should_flag, source in cases:
            path = os.path.join(tmp, "case.lua")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(source)
            flagged = bool(analyse(path))
            ok = flagged == should_flag
            failures += not ok
            print("%-32s expected %-7s got %-7s %s"
                  % (label, "flag" if should_flag else "clean",
                     "flag" if flagged else "clean", "ok" if ok else "FAILED"))
    print("\nself-test: %s" % ("passed" if not failures else "%d FAILED" % failures))
    return failures


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(1 if self_test() else 0)
    sys.exit(1 if scan(sys.argv[1:] or [DEFAULT_SRC]) else 0)
