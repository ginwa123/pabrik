#!/usr/bin/env bash
# Phase P1 smoke: build a guest ext4 image around `pabrik-vm-agent`, boot it on
# Firecracker without root, and complete a framed vsock `hello` round-trip.
#
# Needs: /dev/kvm readable, a firecracker binary, a guest kernel (ELF vmlinux),
# mkfs.ext4 + sha256sum + python3. No tap, no iptables, no sudo.
#
# Usage: scripts/vm-guest-smoke.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vm-smoke}"
rootfs="$work/rootfs"
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
command -v python3 >/dev/null || fail "python3 missing"

rm -rf "$work"
mkdir -p "$rootfs"/{proc,sys,dev,tmp}
say "kernel  $guest_kernel sha256=$(sha256sum "$guest_kernel" | cut -c1-16)"

say "building pabrik-vm-agent (static, x86_64-linux-musl)"
zig build-exe "$repo_root/src/vm_agent/main.zig" \
  -target x86_64-linux-musl -O ReleaseSmall -femit-bin="$rootfs/init"
chmod +x "$rootfs/init"
say "agent   sha256=$(sha256sum "$rootfs/init" | cut -c1-16) bytes=$(stat -c %s "$rootfs/init")"

# Unprivileged: no loop mount, no root — mkfs.ext4 -d populates from a directory.
truncate -s 32M "$image"
mkfs.ext4 -q -F -L pabrik-guest -d "$rootfs" "$image"
e2fsck -fn "$image" >/dev/null
say "image   sha256=$(sha256sum "$image" | cut -c1-16) (32 MiB ext4, e2fsck clean)"

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

say "vsock hello round-trip over the hybrid-vsock unix socket"
python3 "$repo_root/scripts/vm-vsock-hello.py" "$vsock_sock"

# The guest acknowledges `shutdown` and then asks the kernel to power off. On
# this kernel that degrades to "System halted instead" (no ACPI power path), so
# the VM does NOT exit by itself — stopping the VM is the manager's job (P2).
# Asserted here so a silent regression cannot pass as a clean shutdown.
grep -q 'shutdown requested' "$serial_log" || fail "the guest never logged the shutdown request"
say "guest log confirms: $(grep -m1 'shutdown requested' "$serial_log" | tr -d '\r')"
pipestatus="$(grep -m1 'Power off not available' "$serial_log" || true)"
if [ -n "$pipestatus" ]; then
  say "known kernel limitation: $(printf '%s' "$pipestatus" | tr -d '\r')"
fi

kill "$fc_pid" 2>/dev/null || true
wait "$fc_pid" 2>/dev/null || true
fc_pid=""
say "OK - image, rootless boot, vsock hello, guest shutdown ack (serial: $serial_log)"
