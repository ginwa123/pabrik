#!/usr/bin/env bash
# Re-pin the `dev` section of scripts/guest-image.manifest.
#
# apk resolves a dependency closure against the LIVE repository index, so this
# is the one place where the plan (package names) turns into a pinned set
# (hashes). Run it in the builder container and paste the output under the dev
# header; nothing else may write those lines, and reviewing them is the point.
#
# Usage: scripts/resolve-guest-packages.sh [--names "git nodejs npm ..."]
#                                          [--branch v3.24] [--arch x86_64]
#                                          [--out FILE] [--selftest]
#
# Needs: apk-tools, wget, sha256sum, awk, sort, tar — all in the builder image.

set -euo pipefail

names="git nodejs npm python3 rust cargo zig"
arch="x86_64"
out=""
branch=""
selftest=0

say() { printf '[resolve-packages] %s\n' "$*"; }
fail() { printf '[resolve-packages] FAIL %s\n' "$*" >&2; exit 1; }

# APKINDEX has no F: field in apk 3, so the file name is `<P>-<V>.apk`. Feeding
# this a hand-written index is how the selftest pins that assumption.
index_names() { # stdin: an APKINDEX -> `<name>-<version>` per package
  awk '
    /^P:/ { name = substr($0, 3) }
    /^V:/ { version = substr($0, 3) }
    /^$/ { if (name != "" && version != "") print name "-" version; name = ""; version = "" }
    END { if (name != "" && version != "") print name "-" version }
  '
}

repo_of() { # <mapfile> <filename> -> the repository that publishes it
  local map="$1" file="$2" repo
  repo="$(awk -v f="$file" '$1 == f { print $2 }' "$map" | sort -u)"
  [ -n "$repo" ] || return 1
  printf '%s\n' "$repo"
}

manifest_line() { # <sha256> <repo> <file>
  printf '%s  https://dl-cdn.alpinelinux.org/alpine/%s/%s/%s/%s  dev\n' \
    "$1" "$branch" "$2" "$arch" "$3"
}

run_selftest() {
  local ok=0 bad=0 tmp
  tmp="$(mktemp -d)"
  branch="v3.24"
  arch="x86_64"
  printf 'P:7zip\nV:26.01-r0\nA:x86_64\n\nP:git\nV:2.54.0-r0\nA:x86_64\n\nP:broken\n\n' >"$tmp/index"
  printf 'git-2.54.0-r0.apk main\nzig-0.16.0-r1.apk community\n' >"$tmp/map"

  check() { # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
      ok=$((ok + 1))
      printf '  ok   %s\n' "$1"
    else
      bad=$((bad + 1))
      printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
    fi
  }
  check "an index yields one name-version per package" "$(printf '7zip-26.01-r0\ngit-2.54.0-r0')" \
    "$(index_names <"$tmp/index")"
  check "a package with no version is skipped" "0" "$(index_names <"$tmp/index" | grep -c '^broken')"
  check "a main package resolves to main" "main" "$(repo_of "$tmp/map" git-2.54.0-r0.apk)"
  check "a community package resolves to community" "community" "$(repo_of "$tmp/map" zig-0.16.0-r1.apk)"
  if repo_of "$tmp/map" absent-1.0-r0.apk >/dev/null 2>&1; then
    bad=$((bad + 1)); printf '  FAIL an unmapped file was accepted\n'
  else
    ok=$((ok + 1)); printf '  ok   an unmapped file is refused\n'
  fi
  check "a package line names the repository it came from" \
    "abc  https://dl-cdn.alpinelinux.org/alpine/v3.24/community/x86_64/zig-0.16.0-r1.apk  dev" \
    "$(manifest_line abc community zig-0.16.0-r1.apk)"

  rm -rf "$tmp"
  printf '[resolve-packages] selftest: %d ok, %d failed\n' "$ok" "$bad"
  [ "$bad" -eq 0 ] || exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --names) names="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --selftest) selftest=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [ "$selftest" = 1 ]; then
  run_selftest
  exit 0
fi

command -v apk >/dev/null || fail "apk-tools is not installed; run this in the builder container"
command -v wget >/dev/null || command -v curl >/dev/null || fail "wget or curl is required"
[ -n "$branch" ] || branch="v$(cut -d. -f1,2 /etc/alpine-release)"
say "resolving against the live $branch/$arch indexes"
say "this is the only step that needs the network; the output is what gets pinned"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
apk update >"$tmp/apk-update.log" 2>&1 || fail "apk update failed (see $tmp/apk-update.log)"
# shellcheck disable=SC2086  # $names is a deliberate word list
apk fetch --recursive -o "$tmp" $names >"$tmp/apk-fetch.log" 2>&1 \
  || { tail -20 "$tmp/apk-fetch.log" >&2; fail "apk fetch failed"; }
say "fetched $(ls "$tmp"/*.apk | wc -l) packages for: $names"

# Filenames carry no repository, so the index is what maps one back. Both
# indexes are read from the same generation apk fetched against.
: >"$tmp/map"
for repo in main community; do
  url="https://dl-cdn.alpinelinux.org/alpine/$branch/$repo/$arch/APKINDEX.tar.gz"
  if command -v wget >/dev/null; then
    wget -q -O "$tmp/APKINDEX-$repo.tar.gz" "$url" || fail "could not fetch $url"
  else
    curl -fsSL -o "$tmp/APKINDEX-$repo.tar.gz" "$url" || fail "could not fetch $url"
  fi
  tar -xzOf "$tmp/APKINDEX-$repo.tar.gz" APKINDEX | index_names | while read -r nv; do
    printf '%s %s\n' "$nv.apk" "$repo"
  done >>"$tmp/map"
done
say "the two indexes list $(wc -l <"$tmp/map") packages"

lines="$tmp/lines"
for file in "$tmp"/*.apk; do
  base="$(basename "$file")"
  repo="$(repo_of "$tmp/map" "$base")" \
    || fail "no index publishes $base, so its URL cannot be pinned"
  manifest_line "$(sha256sum "$file" | cut -d' ' -f1)" "$repo" "$base" >>"$lines"
done
sort -k3 "$lines" -o "$lines"

if [ -n "$out" ]; then
  cat "$lines" >"$out"
  say "wrote $(wc -l <"$lines") pinned lines to $out"
else
  say "paste these under the dev header of scripts/guest-image.manifest:"
  cat "$lines"
fi
say "OK review every line: a re-pin is a NEW image, never a mutation of the old one"
