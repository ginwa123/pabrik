#!/usr/bin/env bash
# Assemble the guest rootfs image: pinned artifacts from guest-image.manifest,
# plus `pabrik-vm-agent` as /init and (optionally) the protocol probe fixture.
#
# No root, no loop mount: `mkfs.ext4 -d` populates the image straight from a
# directory, so this runs anywhere e2fsprogs is installed.
#
# Usage: scripts/build-guest-image.sh --out IMG [--agent BIN] [--probe BIN]
#                                     [--size 128M] [--cache DIR]
#
# Caveat: run as a non-root user, extraction cannot restore root ownership, so
# the base files end up owned by this uid (see the warning this script prints).
# CI must build as root for a shippable image.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/scripts/guest-image.manifest"
out=""
agent_bin=""
probe_bin=""
size="128M"
cache="${PABRIK_VM_CACHE:-$HOME/.cache/pabrik-vm}"

say() { printf '[guest-image] %s\n' "$*"; }
fail() { printf '[guest-image] FAIL %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --agent) agent_bin="$2"; shift 2 ;;
    --probe) probe_bin="$2"; shift 2 ;;
    --size) size="$2"; shift 2 ;;
    --cache) cache="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$out" ] || fail "--out IMG is required"

command -v mkfs.ext4 >/dev/null || fail "mkfs.ext4 missing (e2fsprogs)"
command -v e2fsck >/dev/null || fail "e2fsck missing (e2fsprogs)"
command -v sha256sum >/dev/null || fail "sha256sum missing"
command -v curl >/dev/null || fail "curl missing"

work="$(dirname "$out")/rootfs"
rm -rf "$work"
mkdir -p "$work" "$cache" "$(dirname "$out")"

# ─── pinned artifacts ────────────────────────────────────────────────────
verified=0
while read -r hash url _; do
  case "$hash" in ""|\#*) continue ;; esac
  [ -n "$url" ] || fail "manifest line without a URL next to $hash"
  [ ${#hash} -eq 64 ] || fail "manifest entry for $url has no 64-char sha256"
  file="$cache/$(basename "$url")"
  if [ ! -f "$file" ]; then
    say "fetching $(basename "$url")"
    curl -sSL -o "$file.part" "$url" || fail "download failed: $url"
    mv "$file.part" "$file"
  fi
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$hash" ] || fail "sha256 mismatch for $(basename "$url"): manifest=$hash actual=$actual"
  say "verified $(basename "$url") sha256=${hash:0:16}"
  tar -xzf "$file" -C "$work" --no-same-owner 2>/dev/null || true
  verified=$((verified + 1))
done <"$manifest"
[ "$verified" -gt 0 ] || fail "the manifest listed no artifacts"

# /bin/sh is an ABSOLUTE symlink to /bin/busybox, so a host-side -x on it
# follows the HOST path and lies. Check the real file instead.
[ -f "$work/bin/busybox" ] || fail "the extracted rootfs has no /bin/busybox"

# ─── our own side ────────────────────────────────────────────────────────
if [ -z "$agent_bin" ]; then
  agent_bin="$(dirname "$out")/init"
  say "building pabrik-vm-agent"
  zig build-exe "$repo_root/src/vm_agent/main.zig" \
    -target x86_64-linux-musl -O ReleaseSmall -femit-bin="$agent_bin"
fi
cp "$agent_bin" "$work/init"
chmod +x "$work/init"

if [ -n "$probe_bin" ]; then
  cp "$probe_bin" "$work/bin/pabrik-probe"
  chmod +x "$work/bin/pabrik-probe"
fi

mkdir -p "$work/workspace" "$work/proc" "$work/sys" "$work/dev" "$work/tmp"

# ─── assemble ────────────────────────────────────────────────────────────
rm -f "$out"
truncate -s "$size" "$out"
mkfs.ext4 -q -F -L pabrik-guest -d "$work" "$out"
e2fsck -fn "$out" >/dev/null || fail "the assembled image is not clean"

if [ "$(id -u)" != "0" ]; then
  say "WARNING built unprivileged: base files are owned by uid $(id -u), so a"
  say "WARNING uid-$(id -u) workload inside the guest can rewrite the base. CI builds as root."
fi

say "image   $out ($size, sha256=$(sha256sum "$out" | cut -d' ' -f1 | cut -c1-16))"
say "agent   sha256=$(sha256sum "$work/init" | cut -d' ' -f1 | cut -c1-16)"
say "entries $(find "$work" -mindepth 1 | wc -l) filesystem objects"
say "OK base.ext4 ready"
