#!/usr/bin/env bash
# The VM manager must not outlive the server that started it. This smoke boots
# `pabrik --saas`, lets it start the manager, boots a workspace VM so the
# manager owns a live Firecracker, then closes the server and asserts that the
# manager AND the VMM it owned are gone.
#
# Usage: scripts/vmd-lifecycle-smoke.sh   (needs /dev/kvm)
# Env:   FC_BIN, GUEST_KERNEL

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-$HOME/firecracker-demo/firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
port=8080
workspace=smokews

say() { printf '[vmd-lifecycle-smoke] %s\n' "$*"; }
fail() { printf '[vmd-lifecycle-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
[ -x "$fc_bin" ] || fail "firecracker not found: $fc_bin (set FC_BIN)"

# PABRIK_BIN points the smoke at another build, so the same script can show
# the old behaviour (the manager outliving the server) on the same box.
pabrik="${PABRIK_BIN:-}"
if [ -z "$pabrik" ]; then
  for candidate in "$repo_root/zig-out/bin/pabrik" "$repo_root"/zig-out/bin/pabrikcore-*; do
    [ -x "$candidate" ] && { pabrik="$candidate"; break; }
  done
fi
[ -n "$pabrik" ] || fail "no pabrik binary under $repo_root/zig-out/bin; run 'zig build' first"
vmd="$repo_root/zig-out/bin/pabrik-vmd"
[ -x "$vmd" ] || fail "no $vmd; run 'zig build vmd' first"

work="$(mktemp -d -t pabrik-vmd-lifecycle-XXXXXX)"
sock="$work/vmd.sock"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill -KILL "$server_pid" 2>/dev/null || true
  pkill -f "pabrik-vmd serve --socket $work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/vms"
"$repo_root/scripts/build-guest-image.sh" --out "$work/base.ext4" --size 128M >/dev/null

export HOME="$work"
export PABRIK_VMD_SOCKET="$sock"
export PABRIK_VM_BASE_IMAGE="$work/base.ext4"
export PABRIK_GUEST_KERNEL="$guest_kernel"
export PABRIK_FC_BIN="$fc_bin"
export PABRIK_VM_DIR="$work/vms"

say "boot the server on port $port; it starts the manager"
"$pabrik" --saas --port "$port" --no-static-dir >"$work/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 600); do
  grep -q "runtime mode: saas" "$work/server.log" && break
  kill -0 "$server_pid" 2>/dev/null || fail "the server never booted: $(tail -n 15 "$work/server.log")"
  sleep 0.1
done
grep -q -- "--saas: started pabrik-vmd" "$work/server.log" \
  || fail "the boot did not start a manager: $(cat "$work/server.log")"
manager_pid="$(pgrep -f "pabrik-vmd serve --socket $work" | head -1)"
[ -n "$manager_pid" ] || fail "no manager process for $sock"
say "ok  server pid $server_pid, manager pid $manager_pid"

say "boot a workspace VM, so the manager owns a live VMM"
"$vmd" exec --socket "$sock" --workspace-id "$workspace" --timeout-ms 120000 -- /bin/echo hello-from-guest \
  >"$work/exec.log" 2>&1 || fail "the guest command failed: $(cat "$work/exec.log")"
grep -q "hello-from-guest" "$work/exec.log" || fail "the guest never answered: $(cat "$work/exec.log")"
vmm_pid="$(pgrep -f "firecracker --api-sock $work/vms/workspaces/$workspace" | head -1)"
[ -n "$vmm_pid" ] || fail "no VMM for the workspace"
say "ok  the guest answered; VMM pid $vmm_pid"

say "close the server"
kill -TERM "$server_pid"
for _ in $(seq 1 100); do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$server_pid" 2>/dev/null && fail "the server did not exit"
server_pid=""
for _ in $(seq 1 100); do
  kill -0 "$manager_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$manager_pid" 2>/dev/null && fail "the manager outlived the server (pid $manager_pid)"
say "ok  the manager is gone"

for _ in $(seq 1 100); do
  kill -0 "$vmm_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$vmm_pid" 2>/dev/null && fail "the VMM outlived the manager (pid $vmm_pid)"
say "ok  the VMM the manager owned is gone too"

grep -q "VM manager stopped" "$work/server.log" \
  || fail "the server did not report stopping the manager: $(tail -n 10 "$work/server.log")"
say "ok  the server reported the graceful stop"

say "OK - the manager and its VMs go down with the server"
