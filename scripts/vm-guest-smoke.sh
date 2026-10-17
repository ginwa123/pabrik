#!/usr/bin/env bash
# Phase P1 smoke: build a guest ext4 image around `pabrik-vm-agent`, boot it on
# Firecracker without root, and drive the protocol: `hello`, `exec` (argv, exit
# code, non-root uid, timeout, output budget), `shutdown`, plus an offline read
# of the image to prove the guest's file survived in the sealed disk.
#
# Needs: /dev/kvm readable, a firecracker binary, a guest kernel (ELF vmlinux),
# e2fsprogs + sha256sum + python3. No tap, no iptables, no sudo.
#
# Usage: scripts/vm-guest-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vm-smoke}"
image="$work/base.ext4"
serial_log="$work/serial.log"
api_sock="$work/api.sock"
vsock_sock="$work/vsock.sock"
fc_pid=""

say() { printf '[vm-smoke] %s\n' "$*"; }
fail() { printf '[vm-smoke] FAIL %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$fc_pid" ] && kill -0 "$fc_pid" 2>/dev/null; then
    kill "$fc_pid" 2>/dev/null || true
    wait "$fc_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

[ -r /dev/kvm ] || fail "/dev/kvm is not readable (the whole point of the preflight)"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin (set FC_BIN)"
command -v mkfs.ext4 >/dev/null || fail "mkfs.ext4 missing (e2fsprogs)"
command -v debugfs >/dev/null || fail "debugfs missing (e2fsprogs)"
[ -f "$repo_root/scripts/guest-image.manifest" ] || fail "guest-image.manifest missing"
command -v python3 >/dev/null || fail "python3 missing"

rm -rf "$work"
mkdir -p "$work"
say "kernel  $guest_kernel sha256=$(sha256sum "$guest_kernel" | cut -c1-16)"

say "building the probe fixture (static x86_64-linux-musl)"
zig build-exe "$repo_root/src/vm_agent/probe.zig" \
  -target x86_64-linux-musl -O ReleaseSmall -femit-bin="$work/pabrik-probe"
say "probe   bytes=$(stat -c %s "$work/pabrik-probe")"

say "assembling the guest image from the pinned manifest"
PABRIK_VM_CACHE="${PABRIK_VM_CACHE:-$HOME/.cache/pabrik-vm}" \
  "$repo_root/scripts/build-guest-image.sh" --out "$image" --probe "$work/pabrik-probe"

say "starting firecracker (unprivileged, no NIC)"
"$fc_bin" --api-sock "$api_sock" --enable-pci >"$work/fc.stdout" 2>&1 &
fc_pid=$!
for _ in $(seq 1 50); do [ -S "$api_sock" ] && break; sleep 0.1; done
[ -S "$api_sock" ] || fail "firecracker API socket never appeared"

api() { curl -sS -X PUT --unix-socket "$api_sock" --data "$2" "http://localhost$1"; }

api /logger "{\"log_path\":\"$work/fc.log\",\"level\":\"Info\",\"show_level\":true}"
api /serial "{\"serial_out_path\":\"$serial_log\"}"
api /boot-source "{\"kernel_image_path\":\"$guest_kernel\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 root=/dev/vda rw init=/init\"}"
api /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$image\",\"is_root_device\":true,\"is_read_only\":false}"
api /vsock "{\"guest_cid\":3,\"uds_path\":\"$vsock_sock\"}"
api /machine-config "{\"vcpu_count\":1,\"mem_size_mib\":256}"
api /actions '{"action_type":"InstanceStart"}'
say "instance started, waiting for the agent banner"

banner=""
for _ in $(seq 1 100); do
  if [ -f "$serial_log" ]; then
    banner="$(grep -m1 'listening on vsock port' "$serial_log" 2>/dev/null || true)"
  fi
  [ -n "$banner" ] && break
  sleep 0.1
done
if [ -z "$banner" ]; then
  say "serial log:"; tail -20 "$serial_log" 2>/dev/null || true
  say "firecracker log:"; tail -20 "$work/fc.log" 2>/dev/null || true
  fail "guest never announced the vsock listener"
fi
say "guest banner: $banner"
say "device setup: $(grep -m1 'device nodes' "$serial_log" | tr -d '\r')"

say "protocol probe (hello, exec, exit code, uid, timeout, output budget, shutdown)"
python3 "$repo_root/scripts/vm-guest-probe.py" "$vsock_sock"

# The guest acknowledged `shutdown`, but it cannot power the VM off: this kernel
# logs "Power off not available: System halted instead" (no ACPI power path), so
# stopping the VM is the manager's job (P2).
grep -q 'shutdown requested' "$serial_log" || fail "the guest never logged the shutdown request"
say "known kernel limitation: $(grep -m1 'Power off not available' "$serial_log" | tr -d '\r')"

kill "$fc_pid" 2>/dev/null || true
wait "$fc_pid" 2>/dev/null || true
fc_pid=""

# A hard VM stop leaves an UNMOUNTED ext4: the guest's committed transaction
# sits in the journal, which debugfs does not replay. e2fsck -fy is the replay
# step — the same one mount would do — and needs no root.
say "offline image read (no mount, no root): does the guest's file persist?"
e2fsck -fy "$image" >/dev/null 2>&1 || true
persisted="$(debugfs -R 'cat /workspace/hello.txt' "$image" 2>/dev/null | head -1)"
[ "$persisted" = "persisted" ] || fail "expected /workspace/hello.txt to contain 'persisted', got '$persisted'"
say "image /workspace/hello.txt = $persisted"

say "OK - image, rootless boot, exec protocol, shutdown ack, persisted file (serial: $serial_log)"
