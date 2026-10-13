#!/usr/bin/env bash
# Ban a skipped test from being invisible in `zig build test`.
#
# WHY THIS EXISTS
# ---------------
# Zig has exactly one way for a test to decline to run:
#
#     test "..." { return error.SkipZigTest; }
#
# and the runner reports it as a SKIP rather than a failure. That is the
# right primitive — a test whose subject genuinely does not exist on this
# host should not be a red build — but it is also the one way a test can
# be silently *wrong* on a platform forever. The suite stays green, the
# `--summary all` line says `(... N skipped)`, and nothing anywhere says
# which platform is not being tested.
#
# That is not hypothetical here. Measured 2026-10-13 on the three
# `backend (<platform>) / build` cells of one green run (38428191906):
#
#     Linux X64    4247/4257 tests passed (10 skipped)
#     macOS ARM64  4229/4244 tests passed (15 skipped)
#     Windows X64  4163/4257 tests passed (94 skipped)   <-- the outlier
#
# Windows skips 9x what Linux does. The overwhelming majority of those
# ninety-four are `if (skipOnWindows()) return error.SkipZigTest;` on a
# test that spawns a `/bin/sh` fixture script. On Windows those tests
# never run at all, so every Windows-only regression in the very code
# they cover (child-process spawn + capture, the git/PR handlers) ships
# with no test behind it.
#
# WHAT THIS SCRIPT ENFORCES
# -------------------------
# The skipped count is a METRIC WITH A CEILING, per platform, and the
# ceiling may only ever fall:
#
#   * count > baseline  -> FAIL. A new skip landed; the platform it
#     covers silently lost coverage.
#   * count < baseline  -> PASS, with a notice naming the exact
#     `--baseline` value to pin, so the ceiling ratchets down in the next
#     change instead of drifting back up.
#   * summary line not found -> FAIL. "I could not measure" must never
#     read as "nothing to report"; that is the one failure mode that
#     ships a violation (same argument as lint-no-catch-unreachable.sh).
#
# WHY A PER-PLATFORM CEILING AND NOT A FLAT ZERO
# ----------------------------------------------
# Zero is the goal, and `--strict` is that check, but it is not yet
# satisfiable: converting the Windows skips needs real Windows runs to
# verify each payload, and pretending otherwise would mean either a
# permanently red job or deleting the tests. The ceiling is what makes
# the number (a) visible in every backend cell, (b) impossible to raise,
# and (c) mechanically lowerable — `--baseline` is in the failure and the
# notice text. CODING_STANDARDS.md §3 carries the rule and the measured
# numbers; the nightly Windows job is how the remainder gets converted.
#
# USAGE
#   check-zig-test-skips.sh --summary <log> --platform windows
#       Parse a captured `zig build test --summary all` log for <platform>.
#   check-zig-test-skips.sh --run [--platform <p>]
#       Run `zig build test --summary all` yourself and check that.
#   check-zig-test-skips.sh --summary <log> --strict
#       Any skip at all is a failure (the end state, used where a
#       platform is expected to be at zero).
#   check-zig-test-skips.sh --baselines
#       Print the pinned ceilings.
#   check-zig-test-skips.sh --selftest
#       Check the parser and the verdict logic against fixtures.
#
# `--platform` defaults to the host, so a local run needs no flag.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── The ceilings ───────────────────────────────────────────────────────
#
# Measured, not guessed: these are the `(... N skipped)` counts from the
# green run cited above (windows: 94 at the time, minus the three
# Windows-only gates this change converted -- task_create x2 and
# browser x1 -- so 91). Lowering one is always safe and is the point of
# the notice below; raising one needs a reviewer to see it in a diff that
# also says which test got a new platform gate.
baseline_for() {
  case "$1" in
    linux)   echo "${PABRIK_ZIG_TEST_SKIPS_LINUX:-10}" ;;
    macos)   echo "${PABRIK_ZIG_TEST_SKIPS_MACOS:-15}" ;;
    windows) echo "${PABRIK_ZIG_TEST_SKIPS_WINDOWS:-91}" ;;
    *) return 1 ;;
  esac
}

host_platform() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo macos ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# ── The parse ──────────────────────────────────────────────────────────
#
# `zig build test --summary all` ends with one aggregate line per test
# step:
#
#     Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (94 skipped)
#
# and the parens are OMITTED entirely when nothing was skipped:
#
#     Build Summary: 14/14 steps succeeded; 4247/4257 tests passed
#
# A log usually holds several `Build Summary:` lines (the later install
# steps print their own, with no test counts), so scan for the LAST line
# that names a test tally and read the counts out of that one. Prints
# "<skipped> <passed> <total>".
parse_summary() {
  local log="$1"
  [ -f "$log" ] || return 3
  local line
  line="$(grep -E 'Build Summary:.*[0-9]+/[0-9]+ tests passed' "$log" | tail -n 1 || true)"
  [ -n "$line" ] || return 2
  local passed total skipped
  passed="$(printf '%s\n' "$line" | sed -nE 's/.* ([0-9]+)\/([0-9]+) tests passed.*/\1/p')"
  total="$(printf '%s\n' "$line" | sed -nE 's/.* ([0-9]+)\/([0-9]+) tests passed.*/\2/p')"
  skipped="$(printf '%s\n' "$line" | sed -nE 's/.* \(([0-9]+) skipped\).*/\1/p')"
  # No parens means the aggregate line has no skip group at all: zero.
  [ -n "$skipped" ] || skipped=0
  [ -n "$passed" ] && [ -n "$total" ] || return 2
  printf '%s %s %s\n' "$skipped" "$passed" "$total"
}

# ── The verdict ────────────────────────────────────────────────────────
#
# 0 = within the ceiling, 1 = over it (or a skip under --strict),
# 2 = could not measure. Callers only care about 0 vs non-zero, but the
# three are kept distinct so the messages can be honest.
verdict() { # verdict <skipped> <baseline> <strict:0|1>
  local skipped="$1" baseline="$2" strict="$3"
  if [ "$strict" -eq 1 ]; then
    [ "$skipped" -eq 0 ] && return 0
    return 1
  fi
  [ "$skipped" -le "$baseline" ] && return 0
  return 1
}

check_log() { # check_log <log> <platform> <strict>
  local log="$1" platform="$2" strict="$3"
  # `|| rc=$?`, NOT `set +e; ...; rc=$?; set -e`: `set` is global shell state,
  # so a function that re-enables errexit before returning makes its OWN
  # non-zero return fatal to the caller -- which is exactly how the first
  # version of this script died inside its own selftest.
  local parsed rc=0
  parsed="$(parse_summary "$log")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "x could not find a 'N/M tests passed' line in '$log'." >&2
    if [ "$rc" -eq 3 ]; then
      echo "  The file does not exist -- the test step never produced a log." >&2
    else
      echo "  The test step did not run, or the log was truncated before its" >&2
      echo "  summary. Failing closed: an unmeasurable skip count must never" >&2
      echo "  read as 'no skips'." >&2
    fi
    return 1
  fi

  local skipped passed total baseline
  skipped="$(echo "$parsed" | cut -d' ' -f1)"
  passed="$(echo "$parsed" | cut -d' ' -f2)"
  total="$(echo "$parsed" | cut -d' ' -f3)"
  baseline="$(baseline_for "$platform")"

  echo "zig build test -- ${platform}: ${passed}/${total} passed, ${skipped} skipped"
  echo "  ceiling for ${platform}: ${baseline} skipped"

  if verdict "$skipped" "$baseline" "$strict"; then
    if [ "$strict" -eq 0 ] && [ "$skipped" -lt "$baseline" ]; then
      # `::notice` is a GitHub Actions workflow command; locally it would
      # just print literal noise, so say the same thing in plain text.
      local pin="PABRIK_ZIG_TEST_SKIPS_$(echo "$platform" | tr '[:lower:]' '[:upper:]')=${skipped}"
      local slack="${platform} now skips ${skipped} (ceiling ${baseline}). Re-pin it as ${pin} in scripts/check-zig-test-skips.sh so the ceiling cannot drift back up."
      if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::notice title=zig test skip ceiling can be lowered::${slack}"
      else
        echo "notice: ${slack}"
      fi
    fi
    echo "ok ${skipped} skipped <= ceiling ${baseline}"
    return 0
  fi

  if [ "$strict" -eq 1 ]; then
    echo "x ${skipped} test(s) skipped on ${platform} -- this platform is expected at zero." >&2
  else
    echo "x ${skipped} tests skipped on ${platform}, ceiling is ${baseline} (+$((skipped - baseline)))." >&2
  fi
  echo >&2
  echo "  A skipped test is coverage the platform does not have. Nothing is" >&2
  echo "  failing, which is exactly why this check exists: the suite reports" >&2
  echo "  green while the platform runs less of it." >&2
  echo >&2
  echo "  What to do, in order of preference (CODING_STANDARDS.md §3):" >&2
  echo "    1. Make the test run here too -- assert the platform's real" >&2
  echo "       behaviour instead of bailing out. Most of these are a" >&2
  echo "       '/bin/sh' fixture payload that has a native equivalent." >&2
  echo "    2. Give the test a portable fixture so it needs no shell at all." >&2
  echo "    3. Only if the subject genuinely does not exist here, keep the" >&2
  echo "       skip AND lower nothing: a new gate raises this ceiling, which" >&2
  echo "       is a deliberate, reviewed edit -- never an accident." >&2
  echo >&2
  echo "  Find the offending sites with:" >&2
  echo "    rg -n 'error\.SkipZigTest' src/" >&2
  return 1
}

# ── Selftest ───────────────────────────────────────────────────────────
#
# The whole product is the parse, so a parse that has stopped matching is
# a silent outage: it would report "could not measure" (or worse, drop a
# skips group) forever. Fixtures live in a tmpdir and are removed on exit.
selftest() {
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp NOW, not at trap time
  trap "rm -rf '$tmp'" EXIT

  local failures=0
  check() { # check <desc> <expected-exit> <actual-exit>
    if [ "$2" -eq "$3" ]; then
      echo "  ok   $1"
    else
      echo "  FAIL $1 (expected exit $2, got $3)"
      failures=$((failures + 1))
    fi
  }
  check_eq() { # check_eq <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
      echo "  ok   $1"
    else
      echo "  FAIL $1 (expected '$2', got '$3')"
      failures=$((failures + 1))
    fi
  }

  echo "selftest: check-zig-test-skips"

  # 1. The real Windows aggregate line.
  cat > "$tmp/windows.log" <<'EOF'
[test] mod_tests split into 2 shard(s) from 4475 scanned test names
Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (94 skipped)
Build Summary: 4/4 steps succeeded
EOF
  check_eq "windows aggregate parses to skipped=94" "94 4163 4257" "$(parse_summary "$tmp/windows.log")"

  # 2. Zero skips: zig omits the parens entirely, so the absence of the
  #    group must mean 0 and not "unparseable".
  cat > "$tmp/zero.log" <<'EOF'
Build Summary: 14/14 steps succeeded; 4247/4257 tests passed
EOF
  check_eq "no parens parses to skipped=0" "0 4247 4257" "$(parse_summary "$tmp/zero.log")"

  # 3. Several summaries in one log: the LAST line with a test tally wins.
  #    (Install steps print their own, without any counts.)
  cat > "$tmp/multi.log" <<'EOF'
Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (94 skipped)
Build Summary: 4/4 steps succeeded
Build Summary: 21/21 steps succeeded
EOF
  check_eq "later count-free summaries are ignored" "94 4163 4257" "$(parse_summary "$tmp/multi.log")"

  # 4. The aggregate line also appears BEFORE the test step's own summary
  #    when a shard fails early; the last tally still wins.
  cat > "$tmp/shards.log" <<'EOF'
Build Summary: 12/12 steps succeeded; 100/200 tests passed (7 skipped)
Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (94 skipped)
EOF
  check_eq "last tally wins over an earlier one" "94 4163 4257" "$(parse_summary "$tmp/shards.log")"

  # 5. No tally at all -> unmeasurable, exit 2.
  printf 'Build Summary: 4/4 steps succeeded\n' > "$tmp/empty.log"
  local rc_empty=0
  parse_summary "$tmp/empty.log" >/dev/null 2>&1 || rc_empty=$?
  check "a log with no tally reports unmeasurable" 2 "$rc_empty"

  # 6. A missing file -> unmeasurable, exit 3 (distinct from "no tally").
  local rc_missing=0
  parse_summary "$tmp/does-not-exist.log" >/dev/null 2>&1 || rc_missing=$?
  check "a missing log reports unmeasurable" 3 "$rc_missing"

  # 7-9. The verdict itself.
  local rc=0
  rc=0; verdict 10 10 0 || rc=$?
  check "at the ceiling passes" 0 "$rc"
  rc=0; verdict 11 10 0 || rc=$?
  check "one over the ceiling fails" 1 "$rc"
  rc=0; verdict 0 10 1 || rc=$?
  check "strict accepts zero skips" 0 "$rc"
  rc=0; verdict 1 10 1 || rc=$?
  check "strict rejects one skip" 1 "$rc"

  # 10. End to end: the verifier, not just its parts.
  # 12. A log AT the ceiling for the platform must pass, and one ABOVE it
  #     must fail — the boundary the whole rule turns on.
  printf 'Build Summary: 14/14 steps succeeded; 4163/4257 tests passed (91 skipped)\n' > "$tmp/at_ceiling.log"
  rc=0; check_log "$tmp/at_ceiling.log" windows 0 >/dev/null 2>&1 || rc=$?
  check "a log AT the windows ceiling passes" 0 "$rc"
  rc=0; check_log "$tmp/windows.log" windows 0 >/dev/null 2>&1 || rc=$?
  check "a log one over the windows ceiling fails" 1 "$rc"
  rc=0; check_log "$tmp/windows.log" linux 0 >/dev/null 2>&1 || rc=$?
  check "the same log fails the tighter linux ceiling" 1 "$rc"
  rc=0; check_log "$tmp/at_ceiling.log" windows 1 >/dev/null 2>&1 || rc=$?
  check "the same log fails --strict" 1 "$rc"
  rc=0; check_log "$tmp/empty.log" windows 0 >/dev/null 2>&1 || rc=$?
  check "an unmeasurable log FAILS (not a pass)" 1 "$rc"

  # 13. Slack under the ceiling must PASS and must say what to re-pin —
  #     that notice is the only thing that lowers a ceiling.
  printf 'Build Summary: 14/14 steps succeeded; 4250/4257 tests passed (5 skipped)\n' > "$tmp/slack.log"
  local notice
  notice="$(check_log "$tmp/slack.log" linux 0 2>/dev/null || true)"
  rc=0; check_log "$tmp/slack.log" linux 0 >/dev/null 2>&1 || rc=$?
  check "slack under the ceiling passes" 0 "$rc"
  case "$notice" in
    *"PABRIK_ZIG_TEST_SKIPS_LINUX=5"*)
      echo "  ok   slack names the exact value to re-pin" ;;
    *)
      echo "  FAIL slack did not name PABRIK_ZIG_TEST_SKIPS_LINUX=5"
      echo "       got: $notice"
      failures=$((failures + 1)) ;;
  esac

  # 11. The ceilings are pinned integers and every platform resolves.
  local p
  for p in linux macos windows; do
    if baseline_for "$p" >/dev/null 2>&1; then
      echo "  ok   ceiling for $p is a pinned integer ($(baseline_for "$p"))"
    else
      echo "  FAIL no ceiling pinned for $p"
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -ne 0 ]; then
    echo "selftest: $failures failure(s)"
    return 1
  fi
  echo "selftest: all checks passed"
  return 0
}

# ── Entry point ────────────────────────────────────────────────────────
summary_log=""
platform=""
strict=0
do_run=0
case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --baselines)
    for p in linux macos windows; do printf '%-8s %s\n' "$p" "$(baseline_for "$p")"; done
    exit 0
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --summary) summary_log="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --baseline) echo "x --baseline is not a flag: the ceilings are pinned in this script" >&2
                echo "  (see --baselines). Lower one by editing it, so the change" >&2
                echo "  is visible in a diff." >&2
                exit 2 ;;
    --strict) strict=1; shift ;;
    --run) do_run=1; shift ;;
    *) echo "usage: $0 (--summary <log>|--run) [--platform linux|macos|windows] [--strict]" >&2
       echo "       $0 --selftest | --baselines" >&2
       exit 2 ;;
  esac
done

if [ -z "$platform" ]; then
  platform="$(host_platform)"
  if [ "$platform" = unknown ]; then
    echo "x cannot infer the platform from uname; pass --platform" >&2
    exit 2
  fi
fi

if [ "$do_run" -eq 1 ]; then
  summary_log="$(mktemp)"
  # shellcheck disable=SC2064  # expand summary_log NOW, not at trap time
  trap "rm -f '$summary_log'" EXIT
  echo "→ zig build test --summary all (logging to $summary_log)"
  set -o pipefail
  zig build test --summary all 2>&1 | tee "$summary_log"
fi

if [ -z "$summary_log" ]; then
  echo "usage: $0 --summary <log> | --run [--platform <p>] [--strict]" >&2
  exit 2
fi

check_log "$summary_log" "$platform" "$strict"
