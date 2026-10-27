#!/usr/bin/env bash
# The teardown leaves no VMM behind — no /dev/kvm, no firecracker, no guest.
#
# The real smokes exercise this against a live VMM, which needs a machine that
# can boot one. The failure it guards is the manager that is wedged or already
# gone when the smoke exits, and that is a plain process problem: a fake manager
# and a fake VMM reproduce it in under a second.
#
# Usage: scripts/vmd-teardown-selftest.sh
# Env:   PABRIK_TEARDOWN_WAIT_TICKS

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 2 ticks (200 ms) instead of the smoke's 5 s: here the wait is a seam, and the
# escalation cases would otherwise spend ten seconds proving nothing extra.
PABRIK_TEARDOWN_WAIT_TICKS="${PABRIK_TEARDOWN_WAIT_TICKS:-2}"
export PABRIK_TEARDOWN_WAIT_TICKS

# shellcheck source=scripts/vmd-teardown.sh
. "$repo_root/scripts/vmd-teardown.sh"

say() { printf '[vmd-teardown-selftest] %s\n' "$*"; }
fail() { printf '[vmd-teardown-selftest] FAIL %s\n' "$*" >&2; exit 1; }

# A unix socket path is capped at 108 bytes, so the sandbox stays shallow.
sandbox="$(mktemp -d "/tmp/pabrik-teardown-$$-XXXXXX")"
mine="$sandbox/vms"
other="$sandbox/other-vms"
export PABRIK_TEARDOWN_LIB="$repo_root/scripts/vmd-teardown.sh"
export PABRIK_FAKE_BLOCK="$sandbox/block.fifo"
mkdir -p "$mine" "$other"
mkfifo "$PABRIK_FAKE_BLOCK"

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  # A failing case is exactly the run that leaks a fixture VMM, and this harness
  # must not leak the one it is here to catch.
  pkill -KILL -f -- "api-sock $sandbox/" 2>/dev/null || true
  rm -rf "$sandbox"
}
trap cleanup EXIT

# A VMM: a process whose command line carries the `--api-sock` the manager
# would have given it, and which ignores every polite signal so only the KILL
# path can end it. It blocks on the fifo, so it has no child of its own, and it
# is not a shell script: the helper drops shells, so a bash fixture would be
# invisible to the count it is here to exercise.
cat >"$sandbox/fake-vmm.py" <<'FAKE'
import os
import signal

for sig in (signal.SIGTERM, signal.SIGUSR1, signal.SIGINT):
    signal.signal(sig, signal.SIG_IGN)
fd = os.open(os.environ["PABRIK_FAKE_BLOCK"], os.O_RDWR)
os.read(fd, 1)
FAKE

# A manager: starts one VMM and then blocks. "$1" is `cooperative` (takes the
# VMM down on SIGUSR1) or `deaf` (ignores SIGUSR1 and SIGTERM, so only KILL and
# the sweep can end it).
cat >"$sandbox/fake-manager" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
python3 "$PABRIK_FAKE_VMM_BIN" --api-sock "$PABRIK_FAKE_VMM_SOCK" &
vmm=$!
take_vms_down() { kill -KILL "$vmm" 2>/dev/null || true; exit 0; }
case "$1" in
  cooperative) trap take_vms_down USR1 ;;
  deaf) trap '' USR1 TERM ;;
esac
wait "$vmm" 2>/dev/null || true
FAKE

counts_as_vmm() { pabrik_count_vmms "$1"; }

# Sets `manager_pid` instead of printing it: a command substitution would make
# the manager a child of a subshell that is already gone.
start_manager() { # start_manager <root> <mode>
  local root="$1" mode="$2"
  mkdir -p "$root"
  PABRIK_FAKE_VMM_BIN="$sandbox/fake-vmm.py" \
  PABRIK_FAKE_VMM_SOCK="$root/workspaces/ws/api.sock" \
    bash "$sandbox/fake-manager" "$mode" &
  manager_pid=$!
  pids+=("$manager_pid")
}

wait_for_count() { # wait_for_count <root> <expected>
  local root="$1" expected="$2" i
  for ((i = 0; i < 50; i++)); do
    [ "$(counts_as_vmm "$root")" = "$expected" ] && return 0
    sleep 0.1
  done
  fail "expected $expected VMM(s) on $root, saw $(counts_as_vmm "$root")"
}

expect_no_manager() { # expect_no_manager <manager-pid> <what>
  if kill -0 "$1" 2>/dev/null; then fail "$2 outlived the teardown"; fi
}

say "a manager that takes its VMs down with it leaves no VMM behind"
start_manager "$mine" cooperative
manager="$manager_pid"
wait_for_count "$mine" 1
say "  ok  the run has 1 VMM and the count says 1"
pabrik_teardown_daemon "$mine" "$manager"
left="$(counts_as_vmm "$mine")"
[ "$left" = "0" ] || fail "the teardown left $left VMM(s) on $mine"
expect_no_manager "$manager" "the cooperative manager"
say "  ok  0 VMMs and no manager after the teardown"

say "a manager that ignores SIGUSR1 and SIGTERM still leaves no VMM behind"
deaf_root="$sandbox/deaf-vms"
start_manager "$deaf_root" deaf
manager="$manager_pid"
wait_for_count "$deaf_root" 1
say "  ok  the run has 1 VMM and the count says 1"
pabrik_teardown_daemon "$deaf_root" "$manager"
left="$(counts_as_vmm "$deaf_root")"
[ "$left" = "0" ] || fail "a deaf manager left $left VMM(s) on $deaf_root"
expect_no_manager "$manager" "a deaf manager"
say "  ok  0 VMMs and no manager after the escalation and the sweep"

say "another run's root is neither counted nor touched"
start_manager "$other" cooperative
other_manager="$manager_pid"
wait_for_count "$other" 1
pabrik_teardown_daemon "$deaf_root" ""
[ "$(counts_as_vmm "$deaf_root")" = "0" ] || fail "a foreign teardown disturbed $deaf_root"
[ "$(counts_as_vmm "$other")" = "1" ] || fail "the other run lost its VMM"
pabrik_teardown_daemon "$other" "$other_manager"
expect_no_manager "$other_manager" "the other run's manager"
say "  ok  the other run kept its VMM until its own teardown"

say "the shell that calls the count is not one of the VMMs it counts"
cat >"$sandbox/selfmatcher" <<'FAKE'
#!/usr/bin/env bash
. "$PABRIK_TEARDOWN_LIB"
pabrik_count_vmms "$1"
FAKE
self_count="$(bash "$sandbox/selfmatcher" "$other" --api-sock "$other/workspaces/ws/api.sock")"
[ "$self_count" = "0" ] ||
  fail "a caller whose own command line quotes the api-sock pattern counted $self_count VMM(s), itself included"
say "  ok  a caller that quotes the pattern counts 0"

printf '[vmd-teardown-selftest] PASS  the teardown leaves no VMM behind, with or without the manager, and only ever its own\n'
