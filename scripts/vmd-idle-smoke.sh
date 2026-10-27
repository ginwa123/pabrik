#!/usr/bin/env bash
# Idle-stop smoke: a workspace's VM is stopped when nobody uses it, its disk
# survives, and the very next request boots it again.
#
# Everything here is private to this run: its own socket, its own VM root under
# /tmp, and a compressed clock (sweep 1 s, idle window 3 s). It must never touch
# a live `pabrik-vmd` or another session's VM.
#
# Usage: scripts/vmd-idle-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR, GUEST_IMAGE
#
# Cases, in order:
#   1. a command boots the VM and answers
#   2. after the idle window the VMM is GONE, the disk is untouched
#   3. the next command boots it again and answers
#   4. `status` polling does not keep the VM alive
#   5. a detached job does keep it alive, until a probe says it is gone
#   6. a guest burning CPU does keep it alive
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-$HOME/firecracker-demo/firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vmd-idle-smoke}"
vmd="$repo_root/zig-out/bin/pabrik-vmd"
vms="$work/vms"
sock="$work/vmd.sock"
image="$work/base.ext4"
ws="demo"
wsdir="$vms/workspaces/$ws"

say() { printf '[vmd-idle-smoke] %s\n' "$*"; }
fail() { printf '[vmd-idle-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
[ -x "$fc_bin" ] || fail "firecracker not found: $fc_bin (set FC_BIN)"

rm -rf "$work"
mkdir -p "$vms"

say "building pabrik-vmd and the guest agent"
(cd "$repo_root" && zig build vmd && zig build vm)
[ -x "$vmd" ] || fail "zig build vmd left no $vmd"

# GUEST_IMAGE lets a run reuse an image that is already on the box: building one
# needs podman as root, which has nothing to do with what this smoke proves.
if [ -n "${GUEST_IMAGE:-}" ]; then
  [ -f "$GUEST_IMAGE" ] || fail "GUEST_IMAGE is not a file: $GUEST_IMAGE"
  say "reusing the guest image at $GUEST_IMAGE"
  cp --reflink=auto "$GUEST_IMAGE" "$image"
else
  say "assembling the guest image"
  "$repo_root/scripts/build-guest-image.sh" --out "$image" | tail -1
fi

daemon_pid=""
cleanup() {
  [ -n "$daemon_pid" ] && kill -KILL "$daemon_pid" 2>/dev/null || true
  pkill -f "pabrik-vmd serve --socket $sock" 2>/dev/null || true
  pkill -f "api-sock $wsdir/api.sock" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# The idle window is 3 s and the sweep is 1 s, so a reap lands a few seconds
# after the last request — and the first sweep after a boot only TAKES the CPU
# sample, which a delta needs two of.
say "starting a private daemon (idle 3 s, grace 1 s, sweep 1 s)"
PABRIK_VM_DIR="$vms" "$vmd" serve --socket "$sock" --base-image "$image" \
  --kernel "$guest_kernel" --fc "$fc_bin" \
  --sweep-interval-ms 1000 --idle-stop-ms 3000 --idle-grace-ms 1000 --idle-cpu-ms 50 \
  >>"$work/vmd.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
  [ -S "$sock" ] && break
  sleep 0.05
done
[ -S "$sock" ] || fail "daemon never created $sock (see $work/vmd.log)"

status_of() { "$vmd" status --socket "$sock" --workspace-id "$ws" 2>/dev/null | head -1; }
state_of() { status_of | cut -d" " -f1; }
vm_alive() { pgrep -f "api-sock $wsdir/api.sock" >/dev/null 2>&1; }

# Waits for the daemon's own verdict, never for a guess: `absent` AND no VMM
# process for this workspace.
wait_absent() {
  local budget="${1:-40}"
  for _ in $(seq 1 "$budget"); do
    if [ "$(state_of)" = "absent" ] && ! vm_alive; then return 0; fi
    sleep 0.5
  done
  return 1
}

say "case 1: a command boots the VM"
t0=$(date +%s%N)
out=$("$vmd" exec --socket "$sock" --workspace-id "$ws" -- /bin/sh -c 'echo idle-smoke-ok' 2>/dev/null)
t1=$(date +%s%N)
[ "$out" = "idle-smoke-ok" ] || fail "the first command answered '$out'"
say "  boot + command: $(( (t1 - t0) / 1000000 )) ms; status: $(status_of)"

disk_size_before=$(stat -c %s "$wsdir/disk.ext4")
say "case 2: after the idle window the VMM is gone and the disk is untouched"
wait_absent 40 || fail "the idle VMM was never reaped (status: $(status_of), vmd.log follows)
$(cat "$work/vmd.log")"
vm_alive && fail "a firecracker process still owns $wsdir/api.sock"
[ -f "$wsdir/disk.ext4" ] || fail "the reaped workspace lost its disk"
[ "$(stat -c %s "$wsdir/disk.ext4")" = "$disk_size_before" ] || fail "the disk changed size across a reap"
say "  reaped; disk still $disk_size_before bytes; log: $(grep -c 'reaped idle workspace' "$work/vmd.log") reap line(s)"

say "case 3: the next command boots it again"
t2=$(date +%s%N)
out=$("$vmd" exec --socket "$sock" --workspace-id "$ws" -- /bin/sh -c 'echo came-back' 2>/dev/null)
t3=$(date +%s%N)
[ "$out" = "came-back" ] || fail "the reboot answered '$out'"
[ "$(state_of)" = "ready" ] || fail "the rebooted VM is not ready: $(status_of)"
say "  cold boot after a reap: $(( (t3 - t2) / 1000000 )) ms"

say "case 4: polling status every 200 ms does not keep the VM alive"
( for _ in $(seq 1 120); do "$vmd" status --socket "$sock" --workspace-id "$ws" >/dev/null 2>&1 || true; sleep 0.2; done ) &
poll_pid=$!
wait_absent 40 || { kill "$poll_pid" 2>/dev/null || true; fail "status polling blocked the reap"; }
kill "$poll_pid" 2>/dev/null || true
wait "$poll_pid" 2>/dev/null || true
say "  reaped while being polled"

say "case 5: a detached job keeps the VM alive until a probe says it is gone"
"$vmd" exec --socket "$sock" --workspace-id "$ws" -- /bin/true >/dev/null 2>&1
spawned=$("$vmd" spawn --socket "$sock" --workspace-id "$ws" --log-name "idle-smoke" -- /bin/sh -c 'sleep 60')
job_pid=$(printf '%s' "$spawned" | sed -n 's/^pid=\([0-9-]*\).*/\1/p')
[ -n "$job_pid" ] || fail "spawn gave no pid: $spawned"
sleep 8
[ "$(state_of)" = "ready" ] || fail "the VM was reaped under a live job: $(status_of)"
vm_alive || fail "the VMM died under a live job"
say "  still ready after 8 s with job pid=$job_pid"

"$vmd" signal --socket "$sock" --workspace-id "$ws" --pid "$job_pid" --signal 9 >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  if ! "$vmd" probe --socket "$sock" --workspace-id "$ws" --pid "$job_pid" 2>/dev/null | grep -q "alive=true"; then break; fi
  sleep 0.3
done
wait_absent 60 || fail "the VM was never reaped after its last job exited (status: $(status_of))"
say "  reaped after the job was reported gone"

say "case 6: a guest burning CPU keeps the VM alive"
"$vmd" exec --socket "$sock" --workspace-id "$ws" -- /bin/true >/dev/null 2>&1
burner=$("$vmd" spawn --socket "$sock" --workspace-id "$ws" --log-name "idle-burner" -- /bin/sh -c 'while :; do :; done')
burner_pid=$(printf '%s' "$burner" | sed -n 's/^pid=\([0-9-]*\).*/\1/p')
[ -n "$burner_pid" ] || fail "spawn gave no pid: $burner"
sleep 8
[ "$(state_of)" = "ready" ] || fail "the VM was reaped while the guest was burning CPU: $(status_of)"
vm_alive || fail "the VMM died while the guest was burning CPU"
say "  still ready after 8 s of guest CPU (pid=$burner_pid)"

"$vmd" signal --socket "$sock" --workspace-id "$ws" --pid "$burner_pid" --signal 9 >/dev/null 2>&1 || true

say "the daemon's own account:"
grep -E 'reaped idle workspace|reaped [0-9]+ idle' "$work/vmd.log" | sed 's/^/  /' | tail -8

say "PASS"
