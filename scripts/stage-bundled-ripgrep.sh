#!/usr/bin/env bash
set -euo pipefail

rg_version="15.2.0"

usage() {
    cat >&2 <<'USAGE'
stage-bundled-ripgrep.sh <pabrik-triple> [dest-binary]
stage-bundled-ripgrep.sh --print <pabrik-triple>

Downloads the pinned upstream ripgrep release for the triple, verifies its
sha256, and extracts the `rg` executable to [dest-binary] (default
zig-out/bin/rg). Set PABRIK_RG_CACHE to reuse a download directory.

Triples: x86_64-linux-gnu, aarch64-linux-gnu, x86_64-macos, aarch64-macos.
Windows uses stage-bundled-ripgrep.ps1.
USAGE
}

upstream_target() {
    case "$1" in
        x86_64-linux-gnu | x86_64-linux-musl) echo "x86_64-unknown-linux-musl" ;;
        aarch64-linux-gnu | aarch64-linux-musl) echo "aarch64-unknown-linux-musl" ;;
        x86_64-macos) echo "x86_64-apple-darwin" ;;
        aarch64-macos) echo "aarch64-apple-darwin" ;;
        *) return 1 ;;
    esac
}

expected_sha256() {
    case "$1" in
        x86_64-unknown-linux-musl) echo "33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c" ;;
        aarch64-unknown-linux-musl) echo "800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915" ;;
        x86_64-apple-darwin) echo "af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1" ;;
        aarch64-apple-darwin) echo "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4" ;;
        *) return 1 ;;
    esac
}

archive_name() {
    echo "ripgrep-${rg_version}-$1.tar.gz"
}

archive_url() {
    echo "https://github.com/BurntSushi/ripgrep/releases/download/${rg_version}/$(archive_name "$1")"
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
dest="${2:-zig-out/bin/rg}"

if ! target="$(upstream_target "$triple")"; then
    echo "no bundled ripgrep is published for triple '${triple}'" >&2
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

cache_dir="${PABRIK_RG_CACHE:-}"
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
        curl -fsSL --connect-timeout 20 --max-time 600 --retry 3 -o "$archive" "$url"
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

extract_dir="${work_dir}/extract-${target}"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"

member="${extract_dir}/ripgrep-${rg_version}-${target}/rg"
if [[ ! -f "$member" ]]; then
    member=""
    while IFS= read -r candidate; do
        member="$candidate"
        break
    done < <(find "$extract_dir" -type f -name rg | sort)
fi

if [[ -z "$member" ]]; then
    echo "the ${target} archive carries no rg executable" >&2
    exit 1
fi

dest_dir="$(dirname "$dest")"
mkdir -p "$dest_dir"
install -m 0755 "$member" "$dest"

version_out=""
if version_out="$("$dest" --version 2>/dev/null | head -n 1)"; then :; fi
echo "staged bundled ripgrep -> ${dest}${version_out:+ (${version_out})}"
