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

# The canonical release URL. Preferred over the API: the API asset endpoint is
# capped at 60 requests/hour per IP, and CI runners share an IP.
archive_url() {
    echo "https://github.com/rustfs/rustfs/releases/download/${rustfs_version}/$(archive_name "$1")"
}

# Fallback for when the release CDN answers 504 (observed 2026-11-08). The
# asset id is pinned to the version above.
asset_id() {
    case "$1" in
        linux-x86_64-gnu) echo "675522651" ;;
        linux-aarch64-gnu) echo "675521975" ;;
        linux-x86_64-musl) echo "675522955" ;;
        linux-aarch64-musl) echo "675522332" ;;
        macos-aarch64) echo "675523423" ;;
        *) return 1 ;;
    esac
}

api_url() {
    echo "https://api.github.com/repos/rustfs/rustfs/releases/assets/$(asset_id "$1")"
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
    echo "fallback=$(api_url "$target")"
    echo "sha256=${want_sha}"
    exit 0
fi

cache_dir="${PABRIK_RUSTFS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pabrik/rustfs}"
mkdir -p "$cache_dir"
work_dir="$cache_dir"
cleanup_work=0
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

fetch() {
    local url="$1" dest="$2" accept="${3:-}"
    if command -v curl >/dev/null 2>&1; then
        if [[ -n "$accept" ]]; then
            curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 \
                -H "Accept: ${accept}" -o "$dest" "$url"
        else
            curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 -o "$dest" "$url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if [[ -n "$accept" ]]; then
            wget --timeout=20 --tries=3 --header="Accept: ${accept}" -qO "$dest" "$url"
        else
            wget --timeout=20 --tries=3 -qO "$dest" "$url"
        fi
    else
        echo "need curl or wget to download ${url}" >&2
        return 1
    fi
}

if [[ -f "$archive" ]] && [[ "$(sha256_of "$archive")" == "$want_sha" ]]; then
    echo "reusing cached $(basename "$archive")"
else
    rm -f "$archive"
    echo "downloading $(basename "$archive")"
    if ! fetch "$url" "$archive"; then
        echo "release CDN failed; retrying through the API asset endpoint" >&2
        fetch "$(api_url "$target")" "$archive" "application/octet-stream" || exit 1
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

# The member's uncompressed size, so a truncated write (a full disk, a quota)
# is caught here instead of shipping a half-written binary.
want_size=""
if command -v unzip >/dev/null 2>&1; then
    want_size="$(unzip -l "$archive" rustfs 2>/dev/null | awk '$NF == "rustfs" { print $1; exit }')"
fi

# Extract to a temp file and rename into place: writing straight to `$dest`
# fails with ETXTBSY when a smoke test left pabrik-fs running, and a rename
# replaces the directory entry without touching the running inode.
staged="${dest}.staged.$$"
trap 'rm -f "$staged"' EXIT

if command -v unzip >/dev/null 2>&1; then
    unzip -p "$archive" rustfs > "$staged"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$staged" <<'PY'
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

if [[ -n "$want_size" ]]; then
    got_size="$(wc -c < "$staged" | tr -d ' ')"
    if [[ "$got_size" != "$want_size" ]]; then
        echo "extracted rustfs is ${got_size} bytes, expected ${want_size} (truncated write?)" >&2
        exit 1
    fi
fi

chmod 0755 "$staged"
mv -f "$staged" "$dest"

# Do NOT execute the staged binary to print its version: on Windows it leaves a
# process behind that locks the file, and the next staging run cannot replace
# it. The sha256 above is the integrity proof; the version is the pinned one.
echo "staged bundled rustfs -> ${dest} (rustfs ${rustfs_version})"
