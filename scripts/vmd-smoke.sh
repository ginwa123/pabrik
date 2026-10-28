#!/usr/bin/env bash
# P2a smoke: `pabrik-vmd` (our own Zig client) boots a workspace VM, runs
# commands in it as the guest's own root, stops it, and the workspace's sealed
# disk persists across boots. No root, no tap, no iptables.
#
# Usage: scripts/vmd-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The work dir holds an extracted guest rootfs, whose 0555 dirs defeat a plain
# `rm -rf`; this helper is the one place that knows how to remove it.
# shellcheck source=scripts/smoke-workdir.sh
. "$repo_root/scripts/smoke-workdir.sh"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vmd-smoke}"
vmd="$repo_root/zig-out/bin/pabrik-vmd"
vms="$work/vms"
ws="demo"

say() { printf '[vmd-smoke] %s\n' "$*"; }
fail() { printf '[vmd-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin"

pabrik_wipe_workdir "$work"
mkdir -p "$work"

say "building pabrik-vmd (zig build vmd)"
(cd "$repo_root" && zig build vmd -Doptimize=ReleaseSafe)
[ -x "$vmd" ] || fail "zig build vmd left no $vmd"
say "pabrik-vmd bytes=$(stat -c %s "$vmd")"

say "assembling the guest image"
"$repo_root/scripts/build-guest-image.sh" --out "$work/base.ext4" | tail -2

run() { PABRIK_VM_DIR="$vms" "$vmd" run --workspace-id "$ws" --base-image "$work/base.ext4" \
  --kernel "$guest_kernel" --fc "$fc_bin" "$@"; }

say "one boot: shell, uid and distro"
out="$(run --timeout-ms 15000 -- /bin/sh -c '. /etc/os-release; echo hello; id -u; echo "$ID $VERSION_ID"' 2>/dev/null)"
expected=$'hello\n0\nfedora 44'
[ "$out" = "$expected" ] || fail "unexpected output: $out"
say "ok  exec over the Zig client -> hello / uid 0 / Fedora 44"

say "a failing command propagates its exit code"
if run -- /bin/sh -c 'echo to-stderr >&2; exit 7' >/dev/null 2>"$work/err.txt"; then
  fail "expected a non-zero exit from 'exit 7'"
fi
grep -q "exit=7" "$work/err.txt" || fail "exit code was not reported: $(cat "$work/err.txt")"
grep -q "to-stderr" "$work/err.txt" || fail "stderr was not forwarded"
say "ok  exit=7 reported and stderr forwarded"

say "the workspace disk survives a stopped VM (sealed, per workspace)"
run -- /bin/sh -c 'echo persisted > /workspace/keep.txt; sync' >/dev/null 2>&1
out="$(run -- /bin/sh -c 'cat /workspace/keep.txt' 2>/dev/null)"
[ "$out" = "persisted" ] || fail "second boot did not see the file: '$out'"
say "ok  /workspace/keep.txt read back after a full VM restart"

say "the timeout kills the command instead of hanging"
if run --timeout-ms 1000 -- /bin/sh -c 'sleep 30' >/dev/null 2>"$work/timeout.txt"; then
  fail "expected the 1 s deadline to trip"
fi
grep -q "timed_out=true" "$work/timeout.txt" || fail "not reported as a timeout: $(cat "$work/timeout.txt")"
say "ok  deadline tripped, reported as timed_out"

say "every path came from the workspace id"
for f in disk.ext4 api.sock vsock.sock serial.log fc.log; do
  [ -e "$vms/workspaces/$ws/$f" ] || fail "missing $f under $vms/workspaces/$ws"
done
[ ! -e "$vms/workspaces/../disk.ext4" ] || fail "no path escaped the workspace dir"
say "ok  $vms/workspaces/$ws/{disk.ext4,api.sock,vsock.sock,serial.log,fc.log}"

say "OK - boot, exec as the guest's own root, exit codes, timeouts, persistence, derived paths"
