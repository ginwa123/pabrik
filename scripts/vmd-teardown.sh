#!/usr/bin/env bash
# Shared by the VM smokes: the stop that leaves no VMM behind.
#
# WHY SIGUSR1, AND WHY THE SWEEP IS NOT REDUNDANT
# ----------------------------------------------
# The manager reads SIGTERM as "stop the daemon, the VMs stay", because the
# manager that is started next adopts them — the contract
# scripts/vmd-daemon-smoke.sh asserts. A smoke wipes its own VM root, so a VMM
# that outlives one has nothing left to serve: it is reparented to
# systemd --user and nothing will ever stop it. SIGUSR1 is the manager's
# "the service is going away, take the VMs with you". The sweep after it exists
# for the manager that is wedged or already dead, where no signal can help.

# How long a stop waits for a process before it escalates, in 100 ms ticks.
pabrik_teardown_wait_ticks="${PABRIK_TEARDOWN_WAIT_TICKS:-50}"

# A VMM is the firecracker binary, exec'd with `--api-sock <root>/…` by the
# manager (src/vmd/vm_client.zig). A SHELL is never a VMM, and one whose command
# line merely quotes the path — `bash -c '… api-sock /tmp/run/…'` — is otherwise
# a match, so the teardown would count and kill the run that asked it.
_pabrik_is_vmm() {
  local exe runner
  exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
  [ -n "$exe" ] || return 1
  runner="$(readlink "/proc/$$/exe" 2>/dev/null)" || return 0
  [ "$exe" != "$runner" ]
}

pabrik_vmm_pids() {
  local root="${1:?pabrik_vmm_pids needs a VM root}"
  local pid
  for pid in $(pgrep -f -- "api-sock ${root%/}/" 2>/dev/null); do
    _pabrik_is_vmm "$pid" || continue
    printf '%s\n' "$pid"
  done
}

pabrik_count_vmms() {
  local root="${1:?pabrik_count_vmms needs a VM root}"
  pabrik_vmm_pids "$root" | grep -c . || true
}

_pabrik_signal_vmms() {
  local root="$1" sig="$2" pid
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill "-$sig" "$pid" 2>/dev/null || true
  done < <(pabrik_vmm_pids "$root")
}

_pabrik_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

_pabrik_wait_gone() {
  local pid="$1" ticks="$2" i
  for ((i = 0; i < ticks; i++)); do
    _pabrik_alive "$pid" || return 0
    sleep 0.1
  done
  ! _pabrik_alive "$pid"
}

_pabrik_wait_vmms_gone() {
  local root="$1" ticks="$2" i
  for ((i = 0; i < ticks; i++)); do
    [ "$(pabrik_count_vmms "$root")" -eq 0 ] && return 0
    sleep 0.1
  done
  [ "$(pabrik_count_vmms "$root")" -eq 0 ]
}

# TERM first so a VMM can release its guest, then KILL for one that will not.
pabrik_sweep_vmms() {
  local root="${1:?pabrik_sweep_vmms needs a VM root}"
  [ "$(pabrik_count_vmms "$root")" -gt 0 ] || return 0
  _pabrik_signal_vmms "$root" TERM
  _pabrik_wait_vmms_gone "$root" "$pabrik_teardown_wait_ticks" && return 0
  _pabrik_signal_vmms "$root" KILL
  _pabrik_wait_vmms_gone "$root" "$pabrik_teardown_wait_ticks" || true
}

pabrik_teardown_daemon() {
  local root="${1:?pabrik_teardown_daemon needs a VM root}"
  local pid="${2:-}"
  if [ -n "$pid" ] && _pabrik_alive "$pid"; then
    kill -USR1 "$pid" 2>/dev/null || true
    if ! _pabrik_wait_gone "$pid" "$pabrik_teardown_wait_ticks"; then
      kill -TERM "$pid" 2>/dev/null || true
      if ! _pabrik_wait_gone "$pid" "$pabrik_teardown_wait_ticks"; then
        kill -KILL "$pid" 2>/dev/null || true
        _pabrik_wait_gone "$pid" "$pabrik_teardown_wait_ticks" || true
      fi
    fi
    wait "$pid" 2>/dev/null || true
  fi
  pabrik_sweep_vmms "$root"
}
