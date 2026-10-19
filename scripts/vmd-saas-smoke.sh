#!/usr/bin/env bash
# P2c smoke: `pabrik --saas` must accept a host only when a manager can actually
# place a command in a VM, and refuse otherwise — a SaaS process that falls back
# to running tenant commands on the host is the one failure the flag exists to
# stop. Local mode (no flag) is asserted unchanged.
#
# The workspace_id-only RPC and the guest exec it drives are asserted by
# scripts/vmd-daemon-smoke.sh; this script covers the boot decision.
#
# Usage: scripts/vmd-saas-smoke.sh   (needs /dev/kvm)
# Env:   FC_BIN, GUEST_KERNEL

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
port=8080

say() { printf '[vmd-saas-smoke] %s\n' "$*"; }
fail() { printf '[vmd-saas-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"

# `zig build` installs the platform artifact as `pabrikcore-<os>-<arch>`; the bare
# `pabrik` name only exists in a tree that also built the desktop app, so accept
# either rather than assuming the checkout is a dev tree.
pabrik=""
for candidate in "$repo_root/zig-out/bin/pabrik" "$repo_root"/zig-out/bin/pabrikcore-*; do
  [ -x "$candidate" ] && { pabrik="$candidate"; break; }
done
[ -n "$pabrik" ] || fail "no pabrik binary under $repo_root/zig-out/bin; run 'zig build' first"

# A fresh HOME keeps the live agent.db (and the :8081 server) out of the run.
work="$(mktemp -d -t pabrik-saas-smoke-XXXXXX)"
export HOME="$work"
sock="$work/vmd.sock"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.3
  for pid in "${pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# Boot the server in the background, wait for a log line, then stop it.
boot_and_expect() { # boot_and_expect <expected-line> <args...>
  local expected="$1"; shift
  local log="$work/server-$RANDOM.log"
  "$pabrik" --port "$port" "$@" >"$log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  for _ in $(seq 1 600); do
    grep -q "$expected" "$log" && { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; echo "$log"; return 0; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "never saw '$expected' from: pabrik --port $port $* (log: $log)\n--- log ---\n$(tail -n 15 "$log")"
}

say "local mode (no flag) still boots on the host runtime"
log="$(boot_and_expect 'runtime mode: local' --no-static-dir)"
say "ok  pabrik --port $port -> runtime mode: local"

say "saas refuses when no manager answers, instead of running commands on the host"
rc=0
PABRIK_VMD_SOCKET="$work/absent.sock" "$pabrik" --saas --port "$port" --no-static-dir \
  >"$work/refusal.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a refused mode, got $rc ($(cat "$work/refusal.log"))"
grep -q "needs a running pabrik-vmd" "$work/refusal.log" \
  || fail "the refusal did not name the fix: $(cat "$work/refusal.log")"
if grep -q "runtime mode" "$work/refusal.log"; then fail "a refused mode still booted"; fi
say "ok  exit 2 and a refusal that names pabrik-vmd"

say "saas boots once a manager answers its ping"
"$repo_root/scripts/build-guest-image.sh" --out "$work/base.ext4" --size 128M >/dev/null
"$repo_root/zig-out/bin/pabrik-vmd" serve --socket "$sock" --base-image "$work/base.ext4" \
  --kernel "$guest_kernel" --fc "$fc_bin" --root "$work/vms" >"$work/vmd.log" 2>&1 &
pids+=("$!")
for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.05; done
[ -S "$sock" ] || fail "the manager never listened on $sock (see $work/vmd.log)"
export PABRIK_VMD_SOCKET="$sock"

log="$(boot_and_expect 'runtime mode: saas' --saas --no-static-dir)"
say "ok  pabrik --saas --port $port -> runtime mode: saas (manager on $sock)"

say "OK - local mode unchanged, and --saas accepted only with a live manager"
