#!/usr/bin/env python3
"""Every `.path` dependency under src/apps/ must name the package directory the
ROOT pin produced.

WHY THIS EXISTS
---------------
`src/apps/admin/build.zig.zon` depends on the `databases` and `kabelweb`
packages by PATH, into the directory the root `zig build` fetched:

    .path = "../../../zig-pkg/databases-0.0.0-vy-<hash>"

That directory name IS the root's `.hash` value (Zig names the extract after
it), so bumping a pin in `build.zig.zon` renames the directory and silently
invalidates every app that hardcoded the old name. It does NOT reproduce on a
developer machine — `zig-pkg/` still holds the previous extract next to the new
one — and it only shows up on a FRESH checkout, where the app's own
`zig build test` dies with

    unable to open '.../src/apps/admin/../../../zig-pkg/databases-0.0.0-vy-<old>': FileNotFound

which reads like a missing dependency, not a stale pin. That is exactly how PR
#1066 turned three green backend cells red on a ruangsql pin bump.

WHAT IT CHECKS
--------------
For every `src/apps/*/build.zig.zon`: each `.path` that points into `zig-pkg/`
must name one of the root `build.zig.zon` `.hash` values. Textual on purpose —
no `zig build`, no `zig-pkg/` needed, so it can run in the cheap `lint` job
before anything is fetched.

Exit 0 when every path agrees with the root pin, 1 otherwise.
"""

import glob
import os
import re
import sys

ROOT_ZON = "build.zig.zon"
APPS_GLOB = "src/apps/*/build.zig.zon"

HASH = re.compile(r'\.hash\s*=\s*"([^"]+)"')
PATH_DEP = re.compile(r'\.path\s*=\s*"([^"]*zig-pkg/[^"]+)"')


def package_name(dirname):
    """`databases-0.0.0-vy-<hash>` -> `databases`."""
    at = dirname.find("-0.0.0")
    return dirname if at < 0 else dirname[:at]


def main():
    if not os.path.exists(ROOT_ZON):
        print("x %s not found — run this from the repo root" % ROOT_ZON, file=sys.stderr)
        return 1

    with open(ROOT_ZON) as fh:
        root_hashes = HASH.findall(fh.read())
    if not root_hashes:
        print("x no .hash entries in %s — the pin format changed; this check cannot pass"
              % ROOT_ZON, file=sys.stderr)
        return 1

    by_package = {}
    for value in root_hashes:
        by_package.setdefault(package_name(value), set()).add(value)

    failures = []
    checked = 0
    for zon in sorted(glob.glob(APPS_GLOB)):
        with open(zon) as fh:
            text = fh.read()
        for raw in PATH_DEP.findall(text):
            checked += 1
            dirname = os.path.basename(raw.rstrip("/"))
            name = package_name(dirname)
            allowed = by_package.get(name)
            if allowed is None:
                continue
            if dirname in allowed:
                continue
            failures.append((zon, raw, sorted(allowed)))

    for zon, raw, allowed in failures:
        print("x %s: .path = \"%s\"" % (zon, raw))
        print("    the root pin is: %s" % ", ".join(allowed))
        print("    a fresh checkout has no such directory — re-point this at the root .hash value")
    if failures:
        print("x %d stale app path dependenc%s" % (len(failures), "y" if len(failures) == 1 else "ies"))
        return 1

    print("ok %d app path dependenc%s agree with the root pins" % (checked, "y" if checked == 1 else "ies"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
