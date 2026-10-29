#!/usr/bin/env bash
# Render the GitHub Release body for ONE release, on stdout.
#
# WHY THIS IS A SCRIPT AND NOT A `sed` LINE IN EACH WORKFLOW
# ---------------------------------------------------------
# Four jobs publish to the same release (three backend cells + android-apk)
# and a GitHub Release row is LAST-WRITER-WINS: softprops/action-gh-release@v2
# takes no lock over the tag, so whichever publisher lands last decides the
# body. The body is therefore byte-identical from every publisher, and the
# only way to keep four `sed` invocations byte-identical is to not have four.
#
# WHAT CHANGED WHEN TAGS BECAME FIRST-CLASS
# -----------------------------------------
# The same body file now serves two kinds of release:
#
#   * `ci-latest` — the rolling release that tracks main's newest green build
#   * `<tag>`     — a versioned release cut by pushing a `v*` tag
#
# Only the headline differs (a rolling build and a tagged release are not the
# same promise), and it is the body's `@@HEADLINE@@` placeholder that carries
# the difference, so the asset documentation below stays in ONE place and
# cannot drift between the two kinds of release.
#
# The routing rule lives in the callers (ci.yml `env.RELEASE_TAG`), not here:
# this script renders what it is told to render, so it can be run by hand.
#
# ENV
#   RELEASE_TAG  release tag to render for; default `ci-latest`
#   SHA          commit the assets were built from        (required)
#   RUN_ID       workflow run number that built them      (required)
#
# USAGE
#   RELEASE_TAG=v1.2.3 SHA=$GITHUB_SHA RUN_ID=42 \
#     bash scripts/ci-render-release-body.sh > "$RUNNER_TEMP/release-body.md"
set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:-ci-latest}"
SHA="${SHA:?SHA is required (the commit these assets were built from)}"
RUN_ID="${RUN_ID:?RUN_ID is required (the workflow run that built them)}"

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src="$here/ci-release-body.md"
if [ ! -f "$src" ]; then
    echo "x $src is missing — nothing to render" >&2
    exit 1
fi

# The two headlines. Deliberately different sentences rather than one
# templated sentence: a rolling build must never read as a release, and a
# release must never read as "whatever main happened to be".
if [ "$RELEASE_TAG" = "ci-latest" ]; then
    headline='Rolling release — binaries from the latest green `main` build.'
else
    headline="Release \`$RELEASE_TAG\` — the tag's own build, with every asset below attached to it."
fi

# sed replacement is not a quoting context: `|` ends the s/// expression and
# `&` means "the whole match", so a tag carrying either would corrupt the
# body instead of failing. A git ref cannot contain `|` or `\`, and `&` in a
# `v*` tag would be pathological — sanitize rather than reason about it.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/_/g'; }

rendered="$(
    sed -e "s|@@HEADLINE@@|$(sed_escape "$headline")|" \
        -e "s|@@RELEASE_TAG@@|$(sed_escape "$RELEASE_TAG")|" \
        -e "s|@@SHA@@|$SHA|" \
        -e "s|@@RUN@@|$RUN_ID|" \
        "$src"
)"

# An unsubstituted placeholder is not a cosmetic bug: `Ci-ok` would go green
# on a release page that literally reads `@@SHA@@`, and that page is the
# public artifact of a tag. Fail instead.
case "$rendered" in
    *@@*)
        echo "x unsubstituted @@placeholder@@ left in the rendered body:" >&2
        printf '%s\n' "$rendered" | grep -n '@@' >&2 || true
        exit 1
        ;;
esac

printf '%s\n' "$rendered"
