#!/usr/bin/env bash
# `--saas`: a BRAND-NEW workspace's FIRST chat runs at `/workspace`, never at a
# host path — the #1003 regression, end to end. The scenario deliberately has no
# kanban task, because a task link was the only thing that used to supply the
# guest cwd, and only the seam's silent mapping hid the disagreement.
#
# Booting a microVM needs /dev/kvm, which no GitHub-hosted functional shard has,
# so this lives with the other KVM smokes (ci-vm-smoke.yml, self-hosted runner).
#
# Usage: scripts/saas-cwd-smoke.sh   (needs /dev/kvm)
# Env:   FC_BIN, GUEST_KERNEL, PABRIK_SAAS_CWD_PORT

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fc_bin="${FC_BIN:-firecracker}"
guest_kernel="${GUEST_KERNEL:-$HOME/firecracker-demo/vmlinux-6.18.51}"
# A server left behind by a cancelled run can still hold a fixed port, and the
# health check below would then be answered by THAT server (a different HOME, a
# different database) while the probe talks to it. Pick a free port unless the
# operator names one.
pick_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}
port="${PABRIK_SAAS_CWD_PORT:-$(pick_free_port)}"
profile="saas-cwd-stub"
marker="PABRIK_CWD_PROBE"
email="cwd-probe@example.invalid"
password="cwd-probe-password"

say() { printf '[saas-cwd-smoke] %s\n' "$*"; }
fail() { printf '[saas-cwd-smoke] FAIL %s\n' "$*" >&2; exit 1; }

[ -r /dev/kvm ] || fail "/dev/kvm is not readable"
[ -f "$guest_kernel" ] || fail "guest kernel not found: $guest_kernel (set GUEST_KERNEL)"
command -v "$fc_bin" >/dev/null || fail "firecracker not found: $fc_bin (set FC_BIN)"
command -v python3 >/dev/null || fail "python3 is required"
# 8081 is this box's live dev server; this smoke must never bind or signal it.
[ "$port" != "8081" ] || fail "port 8081 is reserved; set PABRIK_SAAS_CWD_PORT to another port"

vmd="$repo_root/zig-out/bin/pabrik-vmd"
pabrik=""
for candidate in "$repo_root/zig-out/bin/pabrik" "$repo_root"/zig-out/bin/pabrikcore-*; do
  [ -x "$candidate" ] && { pabrik="$candidate"; break; }
done
[ -n "$pabrik" ] || fail "no pabrik binary under $repo_root/zig-out/bin; run 'zig build' first"

# The guest `uname -r` is asserted against the kernel this smoke boots, so a host
# whose kernel is somehow the same as the guest's must not pass silently.
kernel_release="$(grep -a -m1 -oE 'Linux version [0-9][^[:space:]]*' "$guest_kernel" |
  awk '{print $3}')"
[ -n "$kernel_release" ] || fail "cannot read a version string out of $guest_kernel"
host_release="$(uname -r)"
[ "$kernel_release" != "$host_release" ] ||
  fail "the guest kernel $guest_kernel reports the host's release ($host_release); nothing here would prove a VM ran"

work="$(mktemp -d -t pabrik-saas-cwd-smoke-XXXXXX)"
export HOME="$work"
# A self-hosted runner may export XDG_*: pin pabrik's config, data, state and
# runtime dir to the smoke's HOME, or the smoke reads the operator's install
# (their real config.json and agent.db) instead of its own.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.3
  for pid in "${pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  pkill -f "pabrik-vmd serve --socket $work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

say "guest kernel $guest_kernel -> release $kernel_release (host $host_release)"
say "assembling the guest image"
"$repo_root/scripts/build-guest-image.sh" --out "$work/base.ext4" | tail -1

stub_record="$work/stub"
python3 "$repo_root/scripts/stub_llm_server.py" \
  --port-file "$work/stub.port" \
  --record-dir "$stub_record" \
  --marker "$marker" \
  --tool command \
  --tool-call-id call_cwd_probe_1 \
  --arguments '{"command":"pwd; uname -r","cwd":"{cwd}","timeout":30}' \
  >"$work/stub.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 200); do [ -s "$work/stub.port" ] && break; sleep 0.05; done
[ -s "$work/stub.port" ] || fail "the stub upstream never reported a port: $(cat "$work/stub.log")"
stub_port="$(cat "$work/stub.port")"
llm_url="http://127.0.0.1:$stub_port/v1/chat/completions"
say "stub upstream for the model on 127.0.0.1:$stub_port"

say "booting pabrik --saas --port $port"
# No background model-catalog fetch: this smoke asserts on a chat turn, and a
# fetch started at boot writes the database while the turn reads its config.
env PABRIK_MODEL_CATALOG_FETCH=0 \
  PABRIK_VMD_SOCKET="$work/vmd.sock" \
  PABRIK_VM_BASE_IMAGE="$work/base.ext4" \
  PABRIK_GUEST_KERNEL="$guest_kernel" \
  PABRIK_FC_BIN="$fc_bin" \
  PABRIK_VM_DIR="$work/vms" \
  "$pabrik" --saas --port "$port" --no-static-dir >"$work/server.log" 2>&1 &
pids+=($!)

server_ready() {
  grep -q 'runtime mode: saas' "$work/server.log" 2>/dev/null &&
    # OUR server, on OUR port: another pabrik answering the health check would
    # make every assertion below about a database this smoke never wrote.
    grep -q "Open in your browser: http://127.0.0.1:$port/" "$work/server.log" 2>/dev/null &&
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1
}
for _ in $(seq 1 600); do server_ready && break; sleep 0.1; done
server_ready || fail "pabrik --saas never became ready on port $port (another process may hold it)
--- server log ---
$(tail -n 20 "$work/server.log")"
say "ok  runtime mode: saas on port $port"

"$pabrik" create-admin --email "$email" --password "$password" >"$work/create-admin.log" 2>&1 ||
  fail "pabrik create-admin failed: $(tail -n 5 "$work/create-admin.log")"
say "ok  admin $email created in the smoke HOME"

say "creating a new workspace, then its FIRST chat (no kanban task)"
[ -x "$vmd" ] || fail "no $vmd: run 'zig build vm' first"
rc=0
python3 "$repo_root/scripts/saas-cwd-probe.py" \
  --base-url "http://127.0.0.1:$port" \
  --llm-url "$llm_url" \
  --email "$email" \
  --password "$password" \
  --profile "$profile" \
  --marker "$marker" \
  --guest-release "$kernel_release" \
  --host-release "$host_release" \
  --host-home "$work" \
  --record-dir "$stub_record" 2>&1 | tee "$work/probe.out"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  # The tail is one line repeated when the config never resolves, and that
  # repetition buries everything else: show the boot, count the noise, then
  # what is left of the running log.
  printf -- '--- server log (boot) ---\n%s\n' "$(head -n 25 "$work/server.log" 2>/dev/null)" >&2
  noisy="$(grep -c 'Failed to parse JSON config' "$work/server.log" 2>/dev/null || true)"
  printf -- '--- server log ---\nconfig-parse failures: %s of %s lines\n%s\n' \
    "${noisy:-0}" "$(wc -l <"$work/server.log" 2>/dev/null || echo 0)" \
    "$(grep -v 'Failed to parse JSON config' "$work/server.log" 2>/dev/null | tail -n 30)" >&2
  printf -- '--- vmd log (tail) ---\n%s\n' "$(tail -n 20 "$work/vms/vmd.log" 2>/dev/null)" >&2
  printf -- '--- the stub upstream ---\n%s\n' "$(tail -n 5 "$work/stub.log" 2>/dev/null)" >&2
  # `json_valid` says whether the stored overlay is JSON at all, and the prefix
  # says what it is: a turn that never reaches a model is usually a config the
  # workflow could not parse, not a VM that did not boot.
  printf -- '--- the accounts the server has ---\n%s\n' \
    "$(sqlite3 "$work/.config/pabrik/agent.db" \
      "SELECT email, role, is_active, length(COALESCE(config_json,'')), json_valid(COALESCE(config_json,'')), replace(substr(COALESCE(config_json,''),1,200), char(10), ' ') FROM users;" 2>&1 | head -10)" >&2
  fail "the probe failed (rc=$rc)"
fi

ws="$(sed -n 's/^\[saas-cwd-probe\] new workspace \(ws_[^ ]*\).*/\1/p' "$work/probe.out" | tail -1)"
[ -n "$ws" ] || fail "the probe never reported a workspace id"

say "that workspace's VM answers over the manager (pabrik-vmd exec), no model involved"
out="$(PABRIK_VM_DIR="$work/vms" "$vmd" exec --socket "$work/vmd.sock" --workspace-id "$ws" \
  --timeout-ms 60000 -- /bin/sh -c 'pwd; uname -r' 2>"$work/exec.err")" ||
  fail "pabrik-vmd exec failed: $(cat "$work/exec.err")"
expected=$'/workspace\n'"$kernel_release"
[ "$out" = "$expected" ] ||
  fail "the VM did not answer at /workspace on the guest kernel (want $(printf '%q' "$expected"), got $(printf '%q' "$out"))"
case "$out" in
  *"$work"*) fail "the command ran against the host: $out" ;;
esac
say "ok  $(printf '%s' "$out" | tr '\n' ' ')"

say "OK - a workspace session is rooted at /workspace, and its VM answers on the guest kernel"
