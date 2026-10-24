#!/usr/bin/env bash
# The manager's descriptor budget. Every dispatch (`exec`, `tty`, `fs.*`,
# `spawn`, `probe`, `signal`, `log`) used to bind a fresh hand-off listener —
# one socket, one accept thread — and leak both. A workspace with ~1000
# dispatches therefore exhausted `RLIMIT_NOFILE`, the daemon's own `accept4`
# answered EMFILE, and the daemon exited: `serve failed: AcceptFailed`, with
# every Firecracker VMM it owned left running and orphaned.
#
# This smoke pins the two halves of that incident, and needs no /dev/kvm: the
# listener is bound BEFORE the VM boots, so a workspace whose boot fails still
# exercises the leak.
#
# Usage: scripts/vmd-fd-smoke.sh
# Env:   PABRIK_VMD_BIN, PABRIK_VM_WORKDIR, VMD_FD_LIMIT, VMD_FD_DISPATCHES

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vmd="${PABRIK_VMD_BIN:-$repo_root/zig-out/bin/pabrik-vmd}"
work="${PABRIK_VM_WORKDIR:-${TMPDIR:-/tmp}/pabrik-vmd-fd-smoke}"
limit="${VMD_FD_LIMIT:-64}"
dispatches="${VMD_FD_DISPATCHES:-48}"
sock="$work/vmd.sock"
log="$work/vmd.log"
ws="ws_fd_smoke"

say() { printf '[vmd-fd-smoke] %s\n' "$*"; }
fail() { printf '[vmd-fd-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -x "$vmd" ] || fail "no pabrik-vmd at $vmd (run 'zig build vmd')"

rm -rf "$work"
mkdir -p "$work/root"

daemon_pid=""
cleanup() {
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fds_of() { ls "/proc/$daemon_pid/fd" 2>/dev/null | wc -l; }

say "a burst of $dispatches dispatches under RLIMIT_NOFILE=$limit"
bash -c "ulimit -n $limit; exec '$vmd' serve \
  --socket '$sock' \
  --base-image '$work/no-such-image.ext4' \
  --kernel '$work/no-such-kernel' \
  --agent '$vmd' \
  --fc /bin/false \
  --root '$work/root' \
  --sweep-interval-ms 0" >"$log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { cat "$log" >&2; fail "the daemon never bound $sock"; }

started_at="$(fds_of)"
say "  descriptors at start: $started_at"

sent=0
for _ in $(seq 1 "$dispatches"); do
  kill -0 "$daemon_pid" 2>/dev/null || break
  "$vmd" exec --socket "$sock" --workspace-id "$ws" -- echo hi >/dev/null 2>&1 || true
  sent=$((sent + 1))
done

# 1. The daemon is still there. This is the incident: it exited here.
kill -0 "$daemon_pid" 2>/dev/null ||
  { grep -a 'serve failed' "$log" >&2 || true; fail "the daemon died after $sent dispatches"; }
say "ok  the daemon is still up after $sent dispatches"

# 2. Its descriptor table did not grow with the dispatches.
ended_at="$(fds_of)"
grew=$((ended_at - started_at))
[ "$grew" -le 8 ] ||
  fail "descriptors grew by $grew over $sent dispatches ($started_at -> $ended_at): every dispatch is still binding a listener"
say "ok  descriptors stayed flat ($started_at -> $ended_at over $sent dispatches)"

# 3. The listener was bound once for the workspace, not once per dispatch.
served="$(grep -ac 'agent: serving .* on ' "$log" || true)"
[ "$served" -le 1 ] ||
  fail "the hand-off listener was bound $served times for one workspace: 'ensure' is not a lookup"
say "ok  the hand-off listener was bound $served time(s) for $ws"

# 4. The client still gets an answer (the daemon is not merely alive, it works).
"$vmd" ping --socket "$sock" >/dev/null 2>&1 ||
  fail "the daemon is up but does not answer ping"
say "ok  the daemon answers ping"

say "OK - the descriptor budget survives a dispatch burst, and a starved accept does not end the daemon"
