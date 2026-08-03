#!/usr/bin/env python
"""Cross-checks every L["..."] key referenced in an addon's code against its locale files.

Prints one line per locale per missing key (an untranslated string falls back to English in
game, so these are a translation backlog rather than an error - the exit code is always 0).
Keys used only by historical migration steps or legacy-only pages may be intentionally
untranslated.

Run from the addon's repository root, or point it at one:

    python build/CheckLocales.py
    python build/CheckLocales.py ../MiniHealthNumbers

Every .lua under src/ is scanned except Libs (third party) and Locales (the translations
themselves). It deliberately does not enumerate directories: an earlier version listed
src/Config/*.lua by hand, and when those files moved down a level the check silently dropped
from 251 keys to 29 and reported everything as translated.
"""
from __future__ import print_function

import io
import os
import re
import sys

KEY = re.compile(r"""L\[(["'])((?:[^\\\n]|\\.)*?)\1\]""")

# Addons write their locale tables one of two ways, so both have to be recognised:
#
#   MiniCC     L:SetDefaultStrings({        FrameSort    L["Role"] = "Rolle"
#                  ["Role"] = "Rolle",
#              })
#
# Matching only the indented table form reported every key of every flat-form locale as
# missing - FrameSort came out at 1377 missing and 0 orphaned, which is the giveaway: a file
# whose entries all parse cannot have zero of them referenced.
ENTRY = re.compile(
    r"""^[ \t]*(?:L\s*)?\[(["'])((?:[^\\\n]|\\.)*?)\1\]\s*=[ \t]*(.*)$""", re.M)

# In the flat form the reference locale writes `L["Role"] = nil`, because the key already is
# the English string. That is a declared key, not a gap. In a translated locale the same line
# means nobody has translated it yet, so it counts as missing there.
NIL_VALUE = re.compile(r"^nil\b")

# Not every lookup spells its key out. Both of these are real FrameSort call sites:
#
#   L["Arena - " .. otherArenaSizes]        -- prefix, completed at runtime
#   L[title]                                -- whole key held in a variable
#
# A literal-only scan sees neither, so the keys they reach look unreferenced and get reported
# as orphans - which is how "Arena - 3v3", "Arena - 3v3 & 5v5" and "Raid" came within one
# commit of being deleted as dead weight while still being displayed in the options panel.
CONCAT_KEY = re.compile(r"""L\[(["'])((?:[^\\\n]|\\.)*?)\1\s*\.\.""")
VARIABLE_KEY = re.compile(r"""L\[\s*([A-Za-z_][A-Za-z_0-9.]*)\s*\]""")
# Quoted literals on the right of `name = ...`, to resolve the variable form. Deliberately
# shallow: it recovers `local title = cond and "Raid" or "Group"` without pretending to be a
# Lua interpreter, and over-reporting a key as referenced only ever loses an orphan warning.
STRINGS = re.compile(r"""(["'])((?:[^\\\n]|\\.)*?)\1""")

SKIP_DIRS = ("Libs", "Locales")
# The locale loader, not a translation table.
NOT_A_LOCALE = ("Locale.lua",)


def read(path):
    return io.open(path, encoding="utf-8").read()


def source_files(src_root):
    for base, dirs, files in os.walk(src_root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if name.endswith(".lua"):
                yield os.path.join(base, name)


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    root = argv[1] if len(argv) > 1 else "."
    src_root = os.path.join(root, "src")
    locale_root = os.path.join(src_root, "Locales")

    if not os.path.isdir(locale_root):
        print("no src/Locales under %s - nothing to check" % os.path.abspath(root))
        return 0

    keys = set()
    prefixes = set()
    # Keys a lookup builds at runtime. Kept apart from `keys` because a key that is only ever
    # constructed cannot be checked for translation - there is no literal to compare against -
    # but it must still not be reported as an orphan.
    constructed = set()
    for path in source_files(src_root):
        text = read(path)
        for match in KEY.finditer(text):
            keys.add(match.group(2))
        for match in CONCAT_KEY.finditer(text):
            prefixes.add(match.group(2))
        for match in VARIABLE_KEY.finditer(text):
            name = match.group(1)
            assigned = re.compile(r"""\b%s\s*=([^\n]*)""" % re.escape(name))
            for line in assigned.findall(text):
                for literal in STRINGS.finditer(line):
                    constructed.add(literal.group(2))

    locales = sorted(f[:-4] for f in os.listdir(locale_root)
                     if f.endswith(".lua") and f not in NOT_A_LOCALE)

    # Parse every locale up front: whether a nil value counts as a gap depends on which locale
    # turns out to be the reference, and that is not known until they have all been listed.
    defined = {}
    untranslated = {}
    for locale in locales:
        have, nils = set(), set()
        for match in ENTRY.finditer(read(os.path.join(locale_root, locale + ".lua"))):
            key, value = match.group(2), match.group(3).strip()
            have.add(key)
            if NIL_VALUE.match(value):
                nils.add(key)
        defined[locale] = have
        untranslated[locale] = nils

    reference = "enUS" if "enUS" in defined else (locales[0] if locales else None)

    missing = 0
    for locale in locales:
        gaps = keys - defined[locale]
        if locale != reference:
            gaps |= untranslated[locale] & keys
        for key in sorted(gaps):
            missing += 1
            short = key if len(key) < 80 else key[:77] + "..."
            print("%s: %r" % (locale, short))

    # Strings a locale defines that nothing references any more - dead weight left behind when
    # the code that used them changed. Reported from the reference locale only; a translation
    # carrying an extra key the English file also has is not the translator's problem.
    # A key a lookup builds at runtime is referenced even though no literal spells it out, so
    # those are held back rather than reported as dead.
    def built_at_runtime(key):
        return key in constructed or any(key.startswith(p) for p in prefixes)

    unreferenced = defined.get(reference, set()) - keys if reference else set()
    orphans = sorted(k for k in unreferenced if not built_at_runtime(k))
    dynamic = sorted(k for k in unreferenced if built_at_runtime(k))

    if orphans:
        print("\nDefined in %s but never referenced in code:" % reference)
        for key in orphans:
            short = key if len(key) < 80 else key[:77] + "..."
            print("  %r" % short)

    if dynamic:
        print("\nReached only through a runtime-built key, so not checked for translation:")
        for key in dynamic:
            short = key if len(key) < 80 else key[:77] + "..."
            print("  %r" % short)

    print("\n%d missing entries; %d orphaned in %s; %d keys referenced in code across %d locales"
          % (missing, len(orphans), reference, len(keys), len(locales)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
