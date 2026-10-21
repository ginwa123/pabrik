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
  pkill -f "pabrik-vmd serve --socket $work" 2>/dev/null || true
  for pid in "${pids[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.3
  for pid in "${pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# What the manager looked like WHILE the server was up. The server stops the
# manager it started when it goes down, so a count taken after the kill is 0.
# The sample goes to files: the boot helper runs in a command substitution, so
# its variables would not reach this shell.
sample_manager() {
  pgrep -fc "pabrik-vmd serve --socket $sock" >"$work/managers_up" 2>/dev/null || echo 0 >"$work/managers_up"
  if [ -S "$sock" ]; then echo yes >"$work/socket_up"; else echo no >"$work/socket_up"; fi
}

# Boot the server in the background, wait for a log line, then stop it.
boot_and_expect() { # boot_and_expect <expected-line> <args...>
  local expected="$1"; shift
  local log="$work/server-$RANDOM.log"
  "$pabrik" --port "$port" "$@" >"$log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  for _ in $(seq 1 600); do
    if grep -q "$expected" "$log"; then
      sample_manager
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "$log"
      return 0
    fi
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

say "saas refuses when there is no manager AND nothing to start one with"
rc=0
PABRIK_VMD_SOCKET="$work/absent.sock" \
PABRIK_VM_BASE_IMAGE="$work/absent.ext4" \
PABRIK_GUEST_KERNEL="$work/absent.vmlinux" \
PABRIK_FC_BIN="$work/absent-firecracker" \
PABRIK_VM_DIR="$work/absent-vms" \
  "$pabrik" --saas --port "$port" --no-static-dir >"$work/refusal.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 for a refused mode, got $rc ($(cat "$work/refusal.log"))"
grep -q "needs a running pabrik-vmd" "$work/refusal.log" \
  || fail "the refusal did not name the fix: $(cat "$work/refusal.log")"
grep -q "needs a guest image" "$work/refusal.log" \
  || fail "the refusal did not name the missing artifact: $(cat "$work/refusal.log")"
if grep -q "runtime mode" "$work/refusal.log"; then fail "a refused mode still booted"; fi
say "ok  exit 2, naming both pabrik-vmd and the missing guest image"

say "saas starts its own manager when none is running"
"$repo_root/scripts/build-guest-image.sh" --out "$work/base.ext4" --size 128M >/dev/null
sock="$work/auto.sock"
export PABRIK_VMD_SOCKET="$sock"
export PABRIK_VM_BASE_IMAGE="$work/base.ext4"
export PABRIK_GUEST_KERNEL="$guest_kernel"
export PABRIK_FC_BIN="$fc_bin"
export PABRIK_VM_DIR="$work/vms"

log="$(boot_and_expect 'runtime mode: saas' --saas --no-static-dir)"
grep -q -- "--saas: started pabrik-vmd" "$log" \
  || fail "the boot did not report starting the manager: $(cat "$log")"
[ "$(cat "$work/socket_up")" = "yes" ] || fail "no manager socket at $sock while the server was up"
[ "$(cat "$work/managers_up")" -ge 1 ] || fail "no manager process for $sock while the server was up"
grep -q "serving on $sock" "$work/vms/vmd.log" \
  || fail "the spawned manager never wrote its log: $(cat "$work/vms/vmd.log" 2>/dev/null)"
say "ok  pabrik --saas --port $port -> runtime mode: saas, manager started by the boot"

say "a second boot adopts that manager instead of starting another"
# The first server stays up: the manager it started lives only while it does.
"$pabrik" --port 0 --saas --no-static-dir >"$work/server-first.log" 2>&1 &
first_pid=$!
pids+=("$first_pid")
for _ in $(seq 1 600); do
  grep -q "runtime mode: saas" "$work/server-first.log" && break
  kill -0 "$first_pid" 2>/dev/null || fail "the first server never booted: $(tail -n 15 "$work/server-first.log")"
  sleep 0.1
done
before="$(pgrep -fc "pabrik-vmd serve --socket $sock" || true)"
[ "$before" = "1" ] || fail "expected one manager on $sock, found $before"

log="$(boot_and_expect 'runtime mode: saas' --saas --no-static-dir)"
after="$(cat "$work/managers_up")"
[ "$before" = "$after" ] || fail "a second boot spawned another manager ($before -> $after)"
say "ok  still $after manager(s) on $sock"

say "the manager goes down with the server that started it"
kill -TERM "$first_pid" 2>/dev/null || true
wait "$first_pid" 2>/dev/null || true
for _ in $(seq 1 100); do
  pgrep -f "pabrik-vmd serve --socket $sock" >/dev/null || break
  sleep 0.1
done
pgrep -f "pabrik-vmd serve --socket $sock" >/dev/null \
  && fail "the manager outlived the server that started it"
say "ok  the manager is gone"

say "OK - local mode unchanged, refusals name the artifact, and one flag is enough"
