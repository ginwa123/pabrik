#!/usr/bin/env bash
# P2b smoke: `pabrik-vmd serve` is the daemon the Pabrik server calls. This
# drives it through its own CLI client and asserts the properties the phase is
# for: commands run in the workspace's VM, the peer is authenticated, the VM
# outlives the daemon it was booted by, and no request ever names a path.
# No root, no tap, no iptables.
#
# Usage: scripts/vmd-daemon-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vmd-daemon-smoke}"
vmd="$work/pabrik-vmd"
vms="$work/vms"
sock="$work/vmd.sock"
ws="demo"
image="$work/base.ext4"

say() { printf '[vmd-daemon-smoke] %s\n' "$*"; }
fail() { printf '[vmd-daemon-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin"

rm -rf "$work"
mkdir -p "$work"

say "building pabrik-vmd (host target)"
zig build-exe "$repo_root/src/vmd/main.zig" -O ReleaseSafe -femit-bin="$vmd"

say "assembling the guest image"
"$repo_root/scripts/build-guest-image.sh" --out "$image" --size 128M | tail -1

daemon_pid=""
start_daemon() {
  local extra=("$@")
  PABRIK_VM_DIR="$vms" "$vmd" serve --socket "$sock" --base-image "$image" \
    --kernel "$guest_kernel" --fc "$fc_bin" "${extra[@]}" 2>>"$work/vmd.log" &
  daemon_pid=$!
  for _ in $(seq 1 100); do
    [ -S "$sock" ] && return 0
    sleep 0.05
  done
  fail "daemon never created $sock (see $work/vmd.log)"
}
stop_daemon() {
  [ -n "$daemon_pid" ] || return 0
  kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  daemon_pid=""
}

client() { PABRIK_VM_DIR="$vms" "$vmd" "$@"; }
exec_in() { client exec --socket "$sock" --workspace-id "$ws" "$@"; }
status_of() { client status --socket "$sock" --workspace-id "$ws"; }

start_daemon
trap 'stop_daemon' EXIT

say "the daemon answers a ping"
out="$(client ping --socket "$sock")"
[ "$out" = "pabrik-vmd 0.1" ] || fail "unexpected ping reply: $out"
say "ok  ping -> $out"

say "a command runs inside the workspace's VM, as uid 1000"
out="$(exec_in --timeout-ms 20000 -- /bin/sh -c 'id -u; cat /etc/alpine-release' 2>/dev/null)"
expected=$'1000\n3.24.2'
[ "$out" = "$expected" ] || fail "unexpected exec output: $out"
say "ok  exec -> uid 1000 on Alpine 3.24.2"

say "every path came from the workspace id, and the VMM's pid is recorded"
for f in disk.ext4 api.sock vsock.sock serial.log fc.log fc.pid; do
  [ -e "$vms/workspaces/$ws/$f" ] || fail "missing $f under $vms/workspaces/$ws"
done
vmm_pid="$(tr -d '[:space:]' < "$vms/workspaces/$ws/fc.pid")"
[ -n "$vmm_pid" ] && kill -0 "$vmm_pid" 2>/dev/null || fail "fc.pid does not name a live process: $vmm_pid"
say "ok  $vms/workspaces/$ws/{disk.ext4,api.sock,vsock.sock,serial.log,fc.log,fc.pid}, vmm pid=$vmm_pid"

say "status reports the running VM"
out="$(status_of)"
[ "$out" = "ready pid=$vmm_pid" ] || fail "unexpected status: $out"
say "ok  status -> $out"

say "the VM survives a daemon restart (the daemon adopts what it finds)"
stop_daemon
kill -0 "$vmm_pid" 2>/dev/null || fail "the VMM died with its daemon; a VMM must outlive the manager"
start_daemon
out="$(status_of)"
[ "$out" = "ready pid=$vmm_pid" ] || fail "a fresh daemon lost the VM: $out"
out="$(exec_in --timeout-ms 20000 -- /bin/sh -c 'echo adopted' 2>/dev/null)"
[ "$out" = "adopted" ] || fail "exec after adoption failed: $out"
say "ok  a restarted daemon adopted vmm pid=$vmm_pid and ran a command in it"

say "a request may not name its own paths"
if exec_in --cwd-rel /etc -- /bin/true >/dev/null 2>"$work/err.txt"; then
  fail "an absolute cwd_rel was accepted"
fi
grep -q "refused: bad_request" "$work/err.txt" || fail "cwd_rel was not refused: $(cat "$work/err.txt")"
if client exec --socket "$sock" --workspace-id ../../etc -- /bin/true >/dev/null 2>"$work/err.txt"; then
  fail "a path-shaped workspace id was accepted"
fi
[ -e "$vms/workspaces/../disk.ext4" ] && fail "a workspace id escaped the workspace directory"
say "ok  /etc and ../../etc were refused before any VM was touched"

say "the workspace disk survives a stop, and the next command boots a fresh VM"
out="$(exec_in -- /bin/sh -c 'echo persisted > /workspace/keep.txt; sync' 2>/dev/null || true)"
client stop --socket "$sock" --workspace-id "$ws" >/dev/null
kill -0 "$vmm_pid" 2>/dev/null && fail "stop left the VMM running"
out="$(status_of)"
[ "$out" = "absent pid=0" ] || fail "status after stop was $out"
out="$(exec_in --timeout-ms 20000 -- /bin/sh -c 'cat /workspace/keep.txt' 2>/dev/null)"
[ "$out" = "persisted" ] || fail "the sealed disk did not survive the stop: $out"
new_pid="$(tr -d '[:space:]' < "$vms/workspaces/$ws/fc.pid")"
[ "$new_pid" != "$vmm_pid" ] || fail "the same VMM pid came back after a stop"
say "ok  stop ended vmm pid=$vmm_pid; the next command booted pid=$new_pid and read the file back"

say "a peer the daemon does not expect is refused"
stop_daemon
foreign_uid=$(( $(id -u) + 1 ))
start_daemon --allowed-uid "$foreign_uid"
rc=0
client ping --socket "$sock" >"$work/forged.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a foreign-uid peer was allowed to ping"
grep -q "refused: forbidden_peer" "$work/forged.txt" || fail "refusal did not name forbidden_peer: $(cat "$work/forged.txt")"
grep -q "refused uid=$(id -u) " "$work/vmd.log" || fail "the daemon did not log who it refused"
say "ok  uid $(id -u) was refused by a daemon expecting uid $foreign_uid (SO_PEERCRED, not a claim)"

say "OK - daemon auth, exec in the VM, derived paths, adoption across restarts, stop"
