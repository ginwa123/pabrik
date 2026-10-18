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
vmd="$repo_root/zig-out/bin/pabrik-vmd"
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

say "building pabrik-vmd (zig build vmd)"
(cd "$repo_root" && zig build vmd -Doptimize=ReleaseSafe)
[ -x "$vmd" ] || fail "zig build vmd left no $vmd"

say "assembling the guest image"
"$repo_root/scripts/build-guest-image.sh" --out "$image" --size 128M | tail -1

daemon_pid=""
start_daemon() {
  local extra=("$@")
  PABRIK_VM_DIR="$vms" "$vmd" serve --socket "$sock" --base-image "$image" \
    --kernel "$guest_kernel" --fc "$fc_bin" --sweep-interval-ms 1000 "${extra[@]}" 2>>"$work/vmd.log" &
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

say "the reconciler sweeps on its own clock"
for _ in $(seq 1 40); do grep -q 'swept 1 workspace' "$work/vmd.log" && break; sleep 0.1; done
grep -q 'swept 1 workspace' "$work/vmd.log" || fail "no sweep reached the log (see $work/vmd.log)"
say "ok  $(grep -m1 'swept 1 workspace' "$work/vmd.log" | sed 's/^pabrik-vmd: //')"

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

say "a killed VMM leaves its sockets behind, and the reconciler reclaims them"
stop_daemon
start_daemon --sweep-interval-ms 0
live_pid="$(tr -d '[:space:]' < "$vms/workspaces/$ws/fc.pid")"
kill -9 "$live_pid"
for _ in $(seq 1 50); do kill -0 "$live_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$vms/workspaces/$ws/api.sock" ] || fail "a SIGKILLed VMM was expected to leave api.sock behind"
out="$(status_of)"
[ "$out" = "absent pid=0" ] || fail "status after kill -9 was $out, not absent"
[ -e "$vms/workspaces/$ws/api.sock" ] && fail "the stale api.sock outlived the reconcile"
[ -e "$vms/workspaces/$ws/vsock.sock" ] && fail "the stale vsock.sock outlived the reconcile"
out="$(exec_in --timeout-ms 20000 -- /bin/sh -c 'echo reclaimed')"
[ "$out" = "reclaimed" ] || fail "the first command after a kill -9 failed: $out"
revived_pid="$(tr -d '[:space:]' < "$vms/workspaces/$ws/fc.pid")"
[ "$revived_pid" != "$live_pid" ] || fail "the killed VMM's pid came back"
say "ok  kill -9 left pid=$live_pid dead and its sockets behind; the next command reclaimed them and booted pid=$revived_pid"

say "a socket a VMM nobody recorded owns is refused, never unlinked"
mv "$vms/workspaces/$ws/fc.pid" "$vms/workspaces/$ws/fc.pid.hidden"
out="$(status_of)"
[ "$out" = 'failed pid=0 error="api.sock is owned by a VMM this daemon has no pid for"' ] ||
  fail "a VMM with no recorded pid was not refused: $out"
[ -e "$vms/workspaces/$ws/api.sock" ] || fail "the socket of an unaccounted VMM was unlinked"
rc=0
exec_in -- /bin/true >/dev/null 2>"$work/unaccounted.txt" || rc=$?
[ "$rc" -ne 0 ] || fail "a command ran in a workspace the daemon cannot account for"
mv "$vms/workspaces/$ws/fc.pid.hidden" "$vms/workspaces/$ws/fc.pid"
out="$(status_of)"
[ "$out" = "ready pid=$revived_pid" ] || fail "the workspace did not recover once its pid was back: $out"
say "ok  the unaccounted VMM kept its socket and the workspace recovered with its pid back"

say "a boot that fails is recorded with its reason, then backed off instead of retried"
badroot="$work/vms-bad"
badsock="$work/vmd-bad.sock"
PABRIK_VM_DIR="$badroot" "$vmd" serve --socket "$badsock" --base-image "$work/missing.ext4" \
  --kernel "$guest_kernel" --fc "$fc_bin" --backoff-base-ms 60000 --sweep-interval-ms 0 \
  2>>"$work/vmd-bad.log" &
bad_pid=$!
for _ in $(seq 1 100); do [ -S "$badsock" ] && break; sleep 0.05; done
rc=0
PABRIK_VM_DIR="$badroot" "$vmd" exec --socket "$badsock" --workspace-id demo -- /bin/true \
  >/dev/null 2>"$work/bad-err.txt" || rc=$?
[ "$rc" -ne 0 ] || fail "a workspace whose base image is missing booted anyway"
grep -q "refused: vm_unavailable" "$work/bad-err.txt" || fail "the refusal did not name vm_unavailable: $(cat "$work/bad-err.txt")"
grep -q '^error=DiskCloneFailed' "$badroot/workspaces/demo/vmd.state" ||
  fail "the failed state did not record why: $(cat "$badroot/workspaces/demo/vmd.state")"
out="$(PABRIK_VM_DIR="$badroot" "$vmd" status --socket "$badsock" --workspace-id demo)"
[ "$out" = 'failed pid=0 error="the last attempt failed; waiting before the next"' ] ||
  fail "the failure was not backed off: $out"
kill -TERM "$bad_pid" 2>/dev/null || true
wait "$bad_pid" 2>/dev/null || true
say "ok  a missing base image -> failed(DiskCloneFailed) on disk, and a backoff on the next request"

say "a detached command becomes a JOB in the guest, not a host process"
marker="pabrik-detached-$$"
out="$(client spawn --socket "$sock" --workspace-id "$ws" --log-name bg_smoke.log -- \
  /bin/sh -c "echo $marker; sleep 300")"
job_pid="${out#pid=}"; job_pid="${job_pid%% *}"
job_log="${out#*log=}"
[ -n "$job_pid" ] || fail "spawn did not report a pid: $out"
[ "$job_log" = "/tmp/pabrik/bg_smoke.log" ] || fail "spawn reported log=$job_log, not the daemon's own path"
say "ok  spawn -> pid=$job_pid log=$job_log"

say "the host is not running that command (it is in the VM)"
if ps -eo args | grep -F "$marker" | grep -v grep >/dev/null; then
  fail "the detached command is on the host: $(ps -eo args | grep -F "$marker" | head -1)"
fi
say "ok  ps on the host shows no such command"

say "probe answers for the job through its own VM"
out="$(client probe --socket "$sock" --workspace-id "$ws" --pid "$job_pid")"
case "$out" in alive=true\ state=ready\ boot_pid=*) ;; *) fail "probe did not report a live job: $out";; esac
say "ok  probe -> $out"

say "the job's log is read from inside the VM"
for _ in $(seq 1 40); do
  out="$(client log --socket "$sock" --workspace-id "$ws" --log-name bg_smoke.log 2>/dev/null || true)"
  case "$out" in *"$marker"*) break;; esac
  sleep 0.1
done
case "$out" in *"$marker"*) ;; *) fail "the job's log did not come back through the VM: $out";; esac
say "ok  log -> $(printf '%s' "$out" | head -1)"

say "stopping the job reaches its whole tree inside the VM"
client signal --socket "$sock" --workspace-id "$ws" --pid "$job_pid" >/dev/null
for _ in $(seq 1 40); do
  out="$(client probe --socket "$sock" --workspace-id "$ws" --pid "$job_pid")"
  case "$out" in alive=false\ state=ready*) break;; esac
  sleep 0.1
done
case "$out" in alive=false\ state=ready*) ;; *) fail "the job survived its own kill: $out";; esac
say "ok  signal -> $out"

say "a stopped VM ends its jobs, and the manager says so"
out="$(client spawn --socket "$sock" --workspace-id "$ws" --log-name bg_stop.log -- /bin/sh -c 'sleep 300')"
stop_pid="${out#pid=}"; stop_pid="${stop_pid%% *}"
[ -n "$stop_pid" ] || fail "the second spawn did not report a pid: $out"
client stop --socket "$sock" --workspace-id "$ws" >/dev/null
out="$(client probe --socket "$sock" --workspace-id "$ws" --pid "$stop_pid")"
case "$out" in alive=false\ state=absent*) ;; *) fail "a stopped VM still vouched for its job: $out";; esac
rc=0
client log --socket "$sock" --workspace-id "$ws" --log-name bg_stop.log >/dev/null 2>"$work/job-log.txt" || rc=$?
[ "$rc" -ne 0 ] || fail "a stopped VM still served its job's log"
grep -q "refused: vm_unavailable" "$work/job-log.txt" ||
  fail "the log refusal did not name vm_unavailable: $(cat "$work/job-log.txt")"
say "ok  a stopped VM reports its job as ended (state=absent) and cannot serve its log"

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

say "OK - daemon auth, exec in the VM, derived paths, adoption, stop, detached jobs, and the reconciler"
