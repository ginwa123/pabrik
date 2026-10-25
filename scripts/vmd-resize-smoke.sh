#!/usr/bin/env bash
# P3 smoke: resizing a running workspace's VM, end to end.
#
# Firecracker takes vCPUs and RAM only at `InstanceStart`, so a resize is a
# stop, a record of the size the workspace must boot with, and a start. This
# drives the real manager through its own CLI and asserts the GUEST sees the
# new size: `nproc` and `/proc/meminfo` are read INSIDE the microVM, before and
# after, so a manager that recorded a size and booted the old one cannot pass.
# The disk is the same idea with `df`: the image grows, `resize2fs` hands the
# room to the filesystem, and the file the guest wrote is still there after.
#
# No root, no tap, no iptables.
#
# Usage: scripts/vmd-resize-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
# A dev box usually keeps the demo download in ~/firecracker-demo rather than
# on PATH; CI passes FC_BIN, so this only helps the local run.
if ! command -v "$fc_bin" >/dev/null && [ -x "$HOME/firecracker-demo/firecracker" ]; then
  fc_bin="$HOME/firecracker-demo/firecracker"
fi
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vmd-resize-smoke}"
vmd="$repo_root/zig-out/bin/pabrik-vmd"
vms="$work/vms"
sock="$work/vmd.sock"
ws="resize"
image="$work/base.ext4"

say() { printf '[vmd-resize-smoke] %s\n' "$*"; }
fail() { printf '[vmd-resize-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin"

rm -rf "$work"
mkdir -p "$work"

# The image build wants the agent on disk (`build-guest-image.sh` refuses
# without it), and a fresh checkout has neither binary, so build both.
say "building pabrik-vmd and the guest agent (zig build vmd vm)"
(cd "$repo_root" && zig build vmd vm -Doptimize=ReleaseSafe)
[ -x "$vmd" ] || fail "zig build vmd left no $vmd"

say "assembling the guest image"
"$repo_root/scripts/build-guest-image.sh" --out "$image" | tail -1

daemon_pid=""
start_daemon() {
  PABRIK_VM_DIR="$vms" "$vmd" serve --socket "$sock" --base-image "$image" \
    --kernel "$guest_kernel" --fc "$fc_bin" --sweep-interval-ms 1000 2>>"$work/vmd.log" &
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
# The guest's own view of itself: what it was actually given, not what we asked.
guest_nproc() { exec_in --timeout-ms 60000 -- /bin/sh -c 'nproc' 2>/dev/null | tr -d '[:space:]'; }
guest_mem_kb() {
  exec_in --timeout-ms 60000 -- /bin/sh -c "awk '/^MemTotal/ {print \$2}' /proc/meminfo" 2>/dev/null | tr -d '[:space:]'
}
guest_root_kb() {
  exec_in --timeout-ms 60000 -- /bin/sh -c "df -k / | awk 'NR==2 {print \$2}'" 2>/dev/null | tr -d '[:space:]'
}
vmm_pid() { tr -d '[:space:]' <"$vms/workspaces/$ws/fc.pid"; }
# `status` also prints the size the workspace boots with.
status_is_ready() { case "$1" in "ready pid=$2 "*) return 0 ;; *) return 1 ;; esac; }

start_daemon
trap 'stop_daemon' EXIT

say "the workspace boots with the manager's defaults (1 vCPU, 512 MiB)"
out="$(exec_in --timeout-ms 60000 -- /bin/sh -c 'echo booted' 2>/dev/null)"
[ "$out" = "booted" ] || fail "the first command failed: $out"
n_before="$(guest_nproc)"
mem_before="$(guest_mem_kb)"
[ "$n_before" = "1" ] || fail "expected 1 vCPU before the resize, the guest says $n_before"
# 512 MiB is 524288 kB, of which the kernel keeps most; a wrong boot shows up
# as a number far outside that band.
[ "$mem_before" -gt 400000 ] && [ "$mem_before" -lt 540000 ] ||
  fail "unexpected MemTotal before the resize: ${mem_before} kB"
pid_before="$(vmm_pid)"
say "ok  guest: 1 vCPU, ${mem_before} kB, vmm pid=$pid_before"

say "a file on the workspace disk, to prove the resize does not touch data"
exec_in --timeout-ms 60000 -- /bin/sh -c 'echo before-resize > /workspace/size.txt; sync' >/dev/null 2>&1 ||
  fail "writing the marker file failed"

say "resize -> 2 vCPUs / 1024 MiB (stop, record, start)"
out="$(client resize --socket "$sock" --workspace-id "$ws" --vcpus 2 --mem 1024)"
case "$out" in
  ready*vcpus=2*mem_mib=1024*) ;;
  *) fail "the resize came back as: $out" ;;
esac
say "ok  $out"

say "the GUEST now has 2 vCPUs and about a gigabyte"
n_after="$(guest_nproc)"
mem_after="$(guest_mem_kb)"
[ "$n_after" = "2" ] || fail "the guest has $n_after vCPU(s) after a resize to 2"
[ "$mem_after" -gt 900000 ] || fail "the guest still sees ${mem_after} kB after a resize to 1024 MiB"
[ "$mem_after" -gt "$mem_before" ] || fail "MemTotal did not grow: ${mem_before} -> ${mem_after} kB"
pid_after="$(vmm_pid)"
[ "$pid_after" != "$pid_before" ] || fail "the resize reused vmm pid=$pid_before; a restart must boot a new VMM"
say "ok  guest: $n_after vCPUs, ${mem_after} kB, vmm pid=$pid_after"

say "the size was recorded beside the VM, and the disk kept its data"
spec="$(cat "$vms/workspaces/$ws/vm.spec")"
case "$spec" in *"vcpus=2"*) ;; *) fail "vm.spec does not record vcpus=2: $spec" ;; esac
case "$spec" in *"mem_mib=1024"*) ;; *) fail "vm.spec does not record mem_mib=1024: $spec" ;; esac
out="$(exec_in --timeout-ms 60000 -- /bin/sh -c 'cat /workspace/size.txt' 2>/dev/null)"
[ "$out" = "before-resize" ] || fail "the workspace disk lost its file across the resize: $out"
say "ok  vm.spec=$(printf '%s' "$spec" | tr '\n' ' ') and /workspace/size.txt came back"

say "a second resize goes back down (the record is read at every boot)"
out="$(client resize --socket "$sock" --workspace-id "$ws" --vcpus 1 --mem 512)"
case "$out" in
  ready*vcpus=1*mem_mib=512*) ;;
  *) fail "the second resize came back as: $out" ;;
esac
n_back="$(guest_nproc)"
mem_back="$(guest_mem_kb)"
[ "$n_back" = "1" ] || fail "the guest has $n_back vCPU(s) after a resize back to 1"
[ "$mem_back" -lt "$mem_after" ] || fail "MemTotal did not shrink: ${mem_after} -> ${mem_back} kB"
say "ok  guest: $n_back vCPU, ${mem_back} kB"

say "a request outside the limits is refused and touches nothing"
pid_live="$(vmm_pid)"
if client resize --socket "$sock" --workspace-id "$ws" --vcpus 99 --mem 512 >/dev/null 2>"$work/err.txt"; then
  fail "a resize to 99 vCPUs was accepted"
fi
grep -q "vcpus must be 1..8" "$work/err.txt" || fail "the refusal did not name the limit: $(cat "$work/err.txt")"
if client resize --socket "$sock" --workspace-id "$ws" --vcpus 1 --mem 1000 >/dev/null 2>"$work/err.txt"; then
  fail "a resize to 1000 MiB was accepted (off Firecracker's 128 MiB grid)"
fi
grep -q "multiple of 128" "$work/err.txt" || fail "the alignment refusal was not named: $(cat "$work/err.txt")"
if client resize --socket "$sock" --workspace-id "$ws" --vcpus 2 >/dev/null 2>"$work/err.txt"; then
  fail "a resize without --mem was accepted"
fi
grep -q "resize needs --vcpus N and --mem MIB" "$work/err.txt" ||
  fail "a missing flag was not explained: $(cat "$work/err.txt")"
out="$(status_of)"
status_is_ready "$out" "$pid_live" || fail "a refused resize disturbed the VM: $out"
say "ok  three refusals, and the VM is still ready pid=$pid_live"

say "storage: the disk image grows and the filesystem inside it takes the room"
disk_img="$vms/workspaces/$ws/disk.ext4"
img_before="$(stat -c %s "$disk_img")"
[ "$img_before" = "$((128 * 1024 * 1024))" ] ||
  fail "the workspace image is $img_before bytes, not the 128 MiB base"
root_before="$(guest_root_kb)"
out="$(client resize --socket "$sock" --workspace-id "$ws" --vcpus 1 --mem 512 --disk 512)"
case "$out" in
  ready*disk_mib=512*) ;;
  *) fail "the storage resize came back as: $out" ;;
esac
img_after="$(stat -c %s "$disk_img")"
[ "$img_after" = "$((512 * 1024 * 1024))" ] ||
  fail "the image is $img_after bytes after a resize to 512 MiB"
root_after="$(guest_root_kb)"
[ "$root_after" -gt "$((root_before * 3))" ] ||
  fail "the guest still sees ${root_after} kB of root filesystem, was ${root_before}"
out="$(exec_in --timeout-ms 60000 -- /bin/sh -c 'cat /workspace/size.txt' 2>/dev/null)"
[ "$out" = "before-resize" ] || fail "growing the disk lost the workspace file: $out"
say "ok  image $((img_before / 1048576)) -> $((img_after / 1048576)) MiB, guest root ${root_before} -> ${root_after} kB, file kept"

say "storage only grows: a smaller disk is refused without a restart"
pid_live="$(vmm_pid)"
if client resize --socket "$sock" --workspace-id "$ws" --vcpus 1 --mem 512 --disk 256 >/dev/null 2>"$work/err.txt"; then
  fail "a resize that shrinks the disk was accepted"
fi
grep -q "never shrinks" "$work/err.txt" ||
  fail "the shrink refusal was not named: $(cat "$work/err.txt")"
out="$(status_of)"
status_is_ready "$out" "$pid_live" || fail "the refused shrink disturbed the VM: $out"
[ "$(stat -c %s "$disk_img")" = "$img_after" ] || fail "the refused shrink changed the image"
say "ok  refused, and the VM is still ready pid=$pid_live at 512 MiB of storage"

say "the VM survives a resize with the daemon gone: the size is on disk, not in memory"
stop_daemon
start_daemon
out="$(status_of)"
status_is_ready "$out" "$pid_live" || fail "the VM did not outlive its daemon: $out"
out="$(exec_in --timeout-ms 60000 -- /bin/sh -c 'nproc' 2>/dev/null | tr -d '[:space:]')"
[ "$out" = "1" ] || fail "the adopted VM reports $out vCPUs, not the recorded 1"
say "ok  a fresh daemon adopted pid=$pid_live at the recorded size"

printf '[vmd-resize-smoke] PASS  a resize moved the guest from 1 vCPU/512 MiB to 2/1024 MiB and back, grew its disk 128 -> 512 MiB, and kept the data\n'
