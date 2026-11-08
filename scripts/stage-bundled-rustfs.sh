#!/usr/bin/env bash
set -euo pipefail

rustfs_version="1.0.4"

usage() {
    cat >&2 <<'USAGE'
stage-bundled-rustfs.sh <pabrik-triple> [dest-binary]
stage-bundled-rustfs.sh --print <pabrik-triple>

Downloads the pinned upstream rustfs release for the triple, verifies its
sha256, and extracts the `rustfs` executable to [dest-binary] (default
zig-out/bin/pabrik-fs). The destination name is the caller's: CI writes
`pabrik-fs` so the process shows up as `pabrik-fs` in a task manager and can
never collide with a `rustfs` the user installed.

Triples: x86_64-linux-gnu, aarch64-linux-gnu, x86_64-linux-musl,
aarch64-linux-musl, aarch64-macos. Upstream publishes no x86_64 macOS build,
so that triple fails with a message instead of a broken bundle.
Windows uses stage-bundled-rustfs.ps1.
USAGE
}

upstream_target() {
    case "$1" in
        x86_64-linux-gnu) echo "linux-x86_64-gnu" ;;
        aarch64-linux-gnu) echo "linux-aarch64-gnu" ;;
        x86_64-linux-musl) echo "linux-x86_64-musl" ;;
        aarch64-linux-musl) echo "linux-aarch64-musl" ;;
        aarch64-macos) echo "macos-aarch64" ;;
        x86_64-macos) return 2 ;;
        *) return 1 ;;
    esac
}

expected_sha256() {
    case "$1" in
        linux-x86_64-gnu) echo "4a25e48f5b5ae610a679b5324206962c6fb0eb20a9fa7ab6cb20e178cf6c534b" ;;
        linux-aarch64-gnu) echo "5c2d4dad2685f41635441b685dc4dead225f84bce2a9a365d87f8151ec88a049" ;;
        linux-x86_64-musl) echo "4924ad4b699b9f59943051efedae2d1eb6d4cac503a1b0384c4b25f7c2c31b5c" ;;
        linux-aarch64-musl) echo "81414fd0e41969f4f5c2e0555951cee76d3f224c112c269c80f52b31276f187a" ;;
        macos-aarch64) echo "49057482769d7904ef95dc40457d71122f48cbb8e9e0725a0817a3ec6daf8270" ;;
        *) return 1 ;;
    esac
}

archive_name() {
    echo "rustfs-$1-v${rustfs_version}.zip"
}

archive_url() {
    echo "https://github.com/rustfs/rustfs/releases/download/${rustfs_version}/$(archive_name "$1")"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

print_only=0
if [[ "$1" == "--print" ]]; then
    print_only=1
    shift
fi

triple="$1"
dest="${2:-zig-out/bin/pabrik-fs}"

target_rc=0
target="$(upstream_target "$triple")" || target_rc=$?
if [[ "$target_rc" -eq 2 ]]; then
    echo "rustfs publishes no x86_64 macOS build; ${triple} ships without a bundled object store" >&2
    exit 1
fi
if [[ "$target_rc" -ne 0 ]]; then
    echo "no bundled rustfs is published for triple '${triple}'" >&2
    exit 1
fi
if ! want_sha="$(expected_sha256 "$target")"; then
    echo "no pinned sha256 for '${target}'" >&2
    exit 1
fi

url="$(archive_url "$target")"

if [[ "$print_only" -eq 1 ]]; then
    echo "triple=${triple}"
    echo "upstream=${target}"
    echo "url=${url}"
    echo "sha256=${want_sha}"
    exit 0
fi

cache_dir="${PABRIK_RUSTFS_CACHE:-}"
if [[ -n "$cache_dir" ]]; then
    mkdir -p "$cache_dir"
    work_dir="$cache_dir"
    cleanup_work=0
else
    work_dir="$(mktemp -d)"
    cleanup_work=1
fi
cleanup() {
    if [[ "$cleanup_work" -eq 1 ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

archive="${work_dir}/$(archive_name "$target")"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

if [[ -f "$archive" ]] && [[ "$(sha256_of "$archive")" == "$want_sha" ]]; then
    echo "reusing cached $(basename "$archive")"
else
    rm -f "$archive"
    echo "downloading $(basename "$archive")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 -o "$archive" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --timeout=20 --tries=3 -qO "$archive" "$url"
    else
        echo "need curl or wget to download ${url}" >&2
        exit 1
    fi
fi

got_sha="$(sha256_of "$archive")"
if [[ "$got_sha" != "$want_sha" ]]; then
    rm -f "$archive"
    echo "sha256 mismatch for $(basename "$archive")" >&2
    echo "  expected ${want_sha}" >&2
    echo "  got      ${got_sha}" >&2
    exit 1
fi
echo "sha256 ok (${want_sha})"

dest_dir="$(dirname "$dest")"
mkdir -p "$dest_dir"

if command -v unzip >/dev/null 2>&1; then
    unzip -p "$archive" rustfs > "$dest"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$dest" <<'PY'
import sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as z:
    with z.open("rustfs") as src, open(dest, "wb") as out:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
PY
else
    echo "need unzip or python3 to extract $(basename "$archive")" >&2
    exit 1
fi

chmod 0755 "$dest"

version_out=""
if version_out="$("$dest" --version 2>/dev/null | head -n 1)"; then :; fi
echo "staged bundled rustfs -> ${dest}${version_out:+ (${version_out})}"
