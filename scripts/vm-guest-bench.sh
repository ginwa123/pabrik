#!/usr/bin/env bash
# Phase P3 step 0: measure the sealed guest, not the host it borrows from.
#
# Boots the dev-tier image on Firecracker with one vCPU, drives the workloads
# P3's filesystem decision depends on through the exec protocol (git status,
# npm install, zig build, cargo build, a 500 MiB tarball read and extract, a
# fsync'd write), and runs the identical argv on the host as the second arm.
# The report is the ratio between the two.
#
# Needs /dev/kvm, a firecracker binary, a guest kernel (ELF vmlinux), e2fsprogs,
# python3, and podman or docker for the root image build — the preflight below
# names every tool it checks. No tap, no iptables, no sudo.
#
# Usage: scripts/vm-guest-bench.sh
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_VM_WORKDIR, BENCH_SIZE_MIB, BENCH_MEM_MIB

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
# The image is 4 GiB and /tmp is a tmpfs on this box, so the default work dir
# is the cache directory rather than ${TMPDIR}.
work="${PABRIK_VM_WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pabrik-vm-bench}"
fixtures="$work/fixtures"
image="$work/image/dev.ext4"
host_work="$work/host-arm"
serial_log="$work/serial.log"
api_sock="$work/api.sock"
vsock_sock="$work/vsock.sock"
report="$work/bench.json"
size_mib="${BENCH_SIZE_MIB:-4096}"
mem_mib="${BENCH_MEM_MIB:-1024}"
fc_pid=""

say() { printf '[bench] %s\n' "$*"; }
fail() { printf '[bench] FAIL %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$fc_pid" ] && kill -0 "$fc_pid" 2>/dev/null; then
    kill "$fc_pid" 2>/dev/null || true
    wait "$fc_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

free_mib() { df -P -m "$1" | awk 'NR == 2 { print $4 }'; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable (the whole point of the preflight)"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin (set FC_BIN)"
command -v mkfs.ext4 >/dev/null || fail "mkfs.ext4 missing (e2fsprogs)"
command -v debugfs >/dev/null || fail "debugfs missing (e2fsprogs)"
command -v python3 >/dev/null || fail "python3 missing"
command -v curl >/dev/null || fail "curl missing"
for tool in git npm zig cargo tar dd; do
  command -v "$tool" >/dev/null || fail "$tool is missing on the host, and the control arm runs it"
done

mkdir -p "$work" "$(dirname "$image")"
need=$((size_mib + 4096))
have="$(free_mib "$work")"
[ "$have" -ge "$need" ] || fail "the work dir needs ${need} MiB free: the image, the rootfs it is built from, the fixtures and the host arm, and $work has ${have}"

say "kernel  $guest_kernel sha256=$(sha256sum "$guest_kernel" | cut -c1-16)"
say "work    $work ($have MiB free)"

say "building the agent and the probe fixture (zig build vm)"
(cd "$repo_root" && zig build vm -Doptimize=ReleaseSmall)
agent_bin="$repo_root/zig-out/bin/pabrik-vm-agent"
probe_bin="$repo_root/zig-out/bin/pabrik-probe"
[ -x "$agent_bin" ] || fail "zig build vm left no $agent_bin"
[ -x "$probe_bin" ] || fail "zig build vm left no $probe_bin"
say "agent   bytes=$(stat -c %s "$agent_bin")"

say "generating the fixtures (deterministic: one seed, no network)"
python3 "$repo_root/scripts/vm-guest-bench.py" fixtures --out "$fixtures" >"$work/fixtures.json"

say "assembling the dev-tier guest image around them (root, in a container)"
"$repo_root/scripts/build-guest-image.sh" --out "$image" --tier dev --size "${size_mib}M" \
  --agent "$agent_bin" --probe "$probe_bin" --payload "$fixtures" --in-container
[ -f "$image" ] || fail "the image build left no $image"

say "starting firecracker (1 vCPU, ${mem_mib} MiB, unprivileged, no NIC)"
rm -f "$api_sock" "$vsock_sock" "$serial_log" "$work/fc.log"
"$fc_bin" --api-sock "$api_sock" --enable-pci >"$work/fc.stdout" 2>&1 &
fc_pid=$!
for _ in $(seq 1 100); do [ -S "$api_sock" ] && break; sleep 0.05; done
[ -S "$api_sock" ] || fail "firecracker API socket never appeared"

api() { curl -sS -X PUT --unix-socket "$api_sock" --data "$2" "http://localhost$1"; }

api /logger "{\"log_path\":\"$work/fc.log\",\"level\":\"Info\",\"show_level\":true}"
api /serial "{\"serial_out_path\":\"$serial_log\"}"
api /boot-source "{\"kernel_image_path\":\"$guest_kernel\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 root=/dev/vda rw init=/init\"}"
api /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$image\",\"is_root_device\":true,\"is_read_only\":false}"
api /vsock "{\"guest_cid\":3,\"uds_path\":\"$vsock_sock\"}"
api /machine-config "{\"vcpu_count\":1,\"mem_size_mib\":$mem_mib}"
started="$(date +%s.%N)"
api /actions '{"action_type":"InstanceStart"}'

banner=""
for _ in $(seq 1 1000); do
  if [ -f "$serial_log" ]; then
    banner="$(grep -m1 'listening on vsock port' "$serial_log" 2>/dev/null || true)"
  fi
  [ -n "$banner" ] && break
  sleep 0.01
done
if [ -z "$banner" ]; then
  say "serial log:"; tail -20 "$serial_log" 2>/dev/null || true
  fail "the guest never announced the vsock listener"
fi
boot_seconds="$(awk -v started="$started" -v now="$(date +%s.%N)" 'BEGIN { printf "%.3f", now - started }')"
say "boot    ${boot_seconds}s from InstanceStart to the agent banner (10 ms polling)"
say "guest   $banner"

say "driving the workloads through the exec protocol, host arm interleaved"
only=()
# BENCH_ONLY narrows the run to the rows whose name contains it, which is how a
# failing workload gets iterated on without paying for the whole suite.
[ -z "${BENCH_ONLY:-}" ] || only=(--only "$BENCH_ONLY")
python3 "$repo_root/scripts/vm-guest-bench.py" run \
  --uds "$vsock_sock" --fixtures "$fixtures" --work "$host_work" \
  --image "$image" --boot-seconds "$boot_seconds" "${only[@]}" --json "$report"

say "stopping the VM"
kill "$fc_pid" 2>/dev/null || true
wait "$fc_pid" 2>/dev/null || true
fc_pid=""

if ! rm -rf "$work/image/rootfs" 2>/dev/null || [ -e "$work/image/rootfs" ]; then
  say "note    $work/image/rootfs is root-owned (the image built in a container):"
  say "note    remove it with 'podman unshare rm -rf $work/image/rootfs' when you want the space back"
fi
say "OK report $report (serial: $serial_log)"
