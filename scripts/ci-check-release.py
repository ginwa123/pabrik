#!/usr/bin/env python3
"""Assert a GitHub Release satisfies the release contract for its tag.

WHY THIS EXISTS
---------------
Publishing is four independent jobs (three backend cells + android-apk) racing
to write one release row, and softprops/action-gh-release@v2 takes NO lock over
the tag: each job uploads only its own assets. So a green build proves each
cell built its own binaries -- it proves nothing about the RELEASE having them
all. A tag push that half-published is exactly the bug this check catches
before the release page is the only evidence.

It reads the REST payload of ONE release on stdin (`gh api
repos/<owner>/<repo>/releases/tags/<tag>`), so it runs identically in CI and
by hand against a live release.

THE CONTRACT
------------
  * `tag_name` is the tag asked for
  * not a draft
  * `prerelease` matches the tag: `ci-latest` -> true, a tag containing `-`
    (e.g. `v1.0.0-rc1`) -> true, any other tag -> false
  * every REQUIRED_ASSETS name is present, `state` is `uploaded`, `size` > 0
  * with `--latest-tag`, a non-prerelease release is the repo's "latest"

Extra assets are allowed on purpose: adding a platform asset must not turn an
older tag's release red.

USAGE
  gh api repos/OWNER/REPO/releases/tags/v1.2.3 \\
    | python3 scripts/ci-check-release.py --tag v1.2.3 \\
        [--latest-tag "$(gh api repos/OWNER/REPO/releases/latest --jq .tag_name)"]

Exit status: 0 = contract met, 1 = violation(s) printed as `x ...` lines,
2 = the payload itself is unusable (not JSON / not a release object).
"""

from __future__ import annotations

import argparse
import json
import sys

# The asset names every release must carry, and the only place they are
# listed as a contract. Derived from ci-backend.yml's staging step (one
# `pabrik-<triple>`, `pabrik-desktop-<triple>`, `pabrik-html-<triple>.tar.gz`
# and, on POSIX cells, `rg-pabrik-<triple>`) plus the android job's
# `Pabrik-android-debug.apk`.
#
# Windows contributes TWO assets and no bare exes: its `pabrik`/`pabrik-desktop`
# binaries and `rg-pabrik.exe` all ride inside `pabrik-desktop-<triple>.zip`,
# which is what a Windows user downloads.
REQUIRED_ASSETS = [
    # Linux X64
    "pabrik-x86_64-linux-gnu",
    "pabrik-desktop-x86_64-linux-gnu",
    "pabrik-html-x86_64-linux-gnu.tar.gz",
    "rg-pabrik-x86_64-linux-gnu",
    # macOS ARM64
    "pabrik-aarch64-macos",
    "pabrik-desktop-aarch64-macos",
    "pabrik-html-aarch64-macos.tar.gz",
    "rg-pabrik-aarch64-macos",
    "Pabrik-aarch64-macos.zip",
    # Windows X64
    "pabrik-desktop-x86_64-windows-gnu.zip",
    "pabrik-html-x86_64-windows-gnu.tar.gz",
    # Android
    "Pabrik-android-debug.apk",
]


def expected_prerelease(tag: str) -> bool:
    """The SAME rule the publish steps use. Keep the two in step.

    `ci-latest` is a rolling build, never a release. A semver pre-release tag
    (`v1.0.0-rc1`) is a release, but an explicitly marked pre-release one, so
    it must not steal the "Latest" badge from the last real version.
    """
    if tag == "ci-latest":
        return True
    return "-" in tag


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tag", required=True, help="release tag this payload must describe")
    ap.add_argument(
        "--latest-tag",
        default=None,
        help="the tag GitHub reports as /releases/latest; checked for non-prerelease tags",
    )
    ap.add_argument(
        "--json-file",
        default=None,
        help="read the payload from this file instead of stdin",
    )
    args = ap.parse_args(argv)

    if args.json_file:
        with open(args.json_file, encoding="utf-8") as fh:
            raw = fh.read()
    else:
        raw = sys.stdin.read()

    try:
        rel = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"x payload is not JSON: {exc}", file=sys.stderr)
        return 2
    if not isinstance(rel, dict) or "tag_name" not in rel:
        print("x payload is not a GitHub release object (no `tag_name`)", file=sys.stderr)
        return 2

    want_prerelease = expected_prerelease(args.tag)
    problems: list[str] = []

    actual_tag = rel.get("tag_name")
    if actual_tag != args.tag:
        problems.append(f"tag_name is {actual_tag!r}, expected {args.tag!r}")

    if rel.get("draft"):
        problems.append("release is a DRAFT (a tag release must be published, not drafted)")

    actual_prerelease = bool(rel.get("prerelease"))
    if actual_prerelease != want_prerelease:
        problems.append(
            f"prerelease is {actual_prerelease}, expected {want_prerelease} for tag {args.tag!r}"
        )

    assets = rel.get("assets")
    if not isinstance(assets, list):
        problems.append("payload has no `assets` array")
        assets = []
    by_name = {a.get("name"): a for a in assets if isinstance(a, dict)}

    for name in REQUIRED_ASSETS:
        asset = by_name.get(name)
        if asset is None:
            problems.append(f"missing asset: {name}")
            continue
        state = asset.get("state")
        if state != "uploaded":
            problems.append(f"asset {name} state is {state!r}, expected 'uploaded'")
        size = asset.get("size") or 0
        if size <= 0:
            problems.append(f"asset {name} is empty (size={size})")

    if args.latest_tag is not None and not want_prerelease:
        if args.latest_tag.strip() != args.tag:
            problems.append(
                f"'{args.latest_tag.strip()}' is the repo's latest release, not {args.tag!r} "
                "(make_latest was not honored)"
            )

    extra = sorted(set(by_name) - set(REQUIRED_ASSETS))
    print(f"release {args.tag}: {len(by_name)} asset(s), {len(assets) - len(by_name)} duplicate name(s)")
    if extra:
        print(f"  note: {len(extra)} extra asset(s) not in the contract: {', '.join(extra)}")

    if problems:
        for p in problems:
            print(f"x {p}", file=sys.stderr)
        print(f"x {len(problems)} problem(s) with release {args.tag}", file=sys.stderr)
        return 1

    print(f"ok {args.tag}: contract met (draft=false, prerelease={want_prerelease}, "
          f"{len(REQUIRED_ASSETS)}/{len(REQUIRED_ASSETS)} required assets uploaded)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
