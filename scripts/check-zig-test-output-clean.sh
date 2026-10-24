#!/usr/bin/env bash
# A green `zig build test` must print nothing it cannot attribute.
#
# WHY THIS EXISTS
# ---------------
# Zig's build runner prints `result_stderr` for EVERY step that wrote a byte to
# stderr — including steps that SUCCEEDED — and then appends the argv it ran:
#
#     test
#     +- run test w
#     [default] (warn): tasks_move: stamp last_human_touched_at failed (non-fatal)
#     failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --listen=-
#
# That is the block a FAILING test prints, minus the two things that carry the
# meaning: `N pass, M fail` in the header and `error: 'test.<name>' failed:` in
# the body. So a suite that is GREEN reads like a suite that is broken. Measured
# on main: `zig build test` exited 0 with 4987/4991 tests passed and printed
# five of those blocks; the next agent spent its first turn hunting a failure
# that did not exist.
#
# The cause is never the runner. It is a `std.log.warn` (or a raw print) that a
# PASSING test reaches: a fixture with a minimal schema, a skill body with a
# closing tag, a child killed on purpose. `std.log` lands on the test runner's
# stderr by definition; the project's own Logger does not — it writes through
# its formatter, and no test installs a global one, so
# `if (loggermod.getGlobal()) |logger| logger.warnFmt(…)` is silent in a test and
# still warns in a running server. That is why the fix is the Logger, not a
# filter over the log.
#
# WHAT THIS ENFORCES
# -----------------
# On a green run the log may hold build.zig's own `[test]`/`[build.zig]` header
# lines and nothing else. Each of these is a failure, reported with its line:
#
#   * `[<scope>] (<level>): …`   a log line the runner relayed from a test
#   * `failed command: …`        the tail of a stderr block
#   * `!! …`                     a fixture's raw print (`!! refusing fixture git`)
#   * `… run test w`             the header of such a block
#
# A red run is exempt: it is SUPPOSED to print `error: … failed:`. The script
# says so and exits 0, because the test step has already failed there.
#
# A line the repo genuinely cannot silence in-tree (a vendored dependency's own
# print, e.g. `curl_easy_perform failed` from kabelweb) is admitted with an
# explicit `--allow <regex>` in the CI step — a diff a reviewer sees, never a
# silent baseline. A whole block has to be admitted line by line.
#
# USAGE
#   check-zig-test-output-clean.sh --summary <log>
#       Judge a captured `zig build test --summary all` log.
#   check-zig-test-output-clean.sh --run [-- <zig build args>]
#       Run `zig build test --summary all` yourself and judge that.
#   check-zig-test-output-clean.sh --allow '<regex>' …
#       Admit lines matching <regex> (repeatable), applied before the verdict.
#   check-zig-test-output-clean.sh --selftest
#       Check the parser and the verdict against fixtures.
#
# EXIT: 0 clean (or a red run), 1 output not clean, 2 could not measure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALLOW_FILE="$(mktemp)"
RUN_LOG=""
SELFTEST_TMP=""
# shellcheck disable=SC2016  # the braces expand when the trap fires, not now
trap 'rm -f "$ALLOW_FILE" ${RUN_LOG:+"$RUN_LOG"}' EXIT

# ── The summary line ───────────────────────────────────────────────────
#
# A log holds several `Build Summary:` lines (each install step prints one);
# only the LAST one carries a test tally. Prints "<steps_total> <steps_failed>",
# and returns 2 when there is no tally (an unmeasurable run must fail closed).
parse_summary() { # parse_summary <log>
  local log="$1"
  [ -f "$log" ] || return 3
  local line
  line="$(grep -E 'Build Summary:.*[0-9]+/[0-9]+ tests passed' "$log" | tail -n 1 || true)"
  [ -n "$line" ] || return 2
  # Everything before the first ';' is the step group: `24/24 steps succeeded`
  # or `1/3 steps succeeded (1 failed)`.
  local steps="${line#Build Summary: }"
  steps="${steps%%;*}"
  local total
  total="$(printf '%s\n' "$steps" | sed -nE 's|^([0-9]+)/[0-9]+ steps.*|\1|p')"
  [ -n "$total" ] || return 2
  local failed=0
  case "$steps" in *failed*) failed=1 ;; esac
  printf '%s %s\n' "$total" "$failed"
}

# ── The scan ───────────────────────────────────────────────────────────
#
# A raw print carries no `[scope] (level):` prefix, so the shapes alone miss
# it (Windows CI: `terminal: this host's pseudoconsole never produced a
# byte …`). Match the BLOCK instead — its `<step> w` header through its
# `failed command:` tail — and report every line inside it, whatever a
# future site prints. awk keeps the line numbers, so the report still points
# at a line of the log.
offenders() { # offenders <log>
  awk '
    { sub(/\r$/, "") }
    / w$/ && ($0 ~ /^[ |`+-]*test/ || $0 ~ /^[ |`+-]*run test/) { in_block = 1; print; next }
    /^failed command: / { print; in_block = 0; next }
    in_block && !/^[[:space:]]*$/ { print; next }
    /^\[[a-zA-Z_]+\] \((warn|info|debug|err)\):/ { print; next }
    /^!! / { print; next }
  ' "$1" 2>/dev/null \
    | { if [ -s "$ALLOW_FILE" ]; then grep -vE -f "$ALLOW_FILE" || true; else cat; fi; } \
    || true
}

report_offenders() { # report_offenders <log>
  local found
  found="$(offenders "$1")"
  [ -n "$found" ] || return 0
  echo "x a GREEN 'zig build test' printed $(printf '%s\n' "$found" | wc -l | tr -d ' ') line(s) that are not a test result:" >&2
  # `cut`: a Windows `failed command:` line carries the whole PATH (4 KB) and
  # buries every other line of the report.
  printf '%s\n' "$found" | cut -c1-200 | sed -e 's/^/    /' >&2
  cat >&2 <<'MSG'

  Each of those is a PASSING test's stderr, which Zig relays under a `run test w`
  header — the same shape as a failure, without the name. Fix the site, do not
  filter the log:
    std.log.warn(…)     -> if (loggermod.getGlobal()) |l| l.warnFmt(…)
    std.debug.print(…)  -> Logger.debugPrint(…)   (module-level, test-silent)
  A warn or print that only a FAILING test can reach can stay as it is.
MSG
  return 1
}

check_log() { # check_log <log>
  local parsed rc=0
  parsed="$(parse_summary "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "x could not find a 'N/M tests passed' line in '$1'." >&2
    if [ "$rc" -eq 3 ]; then
      echo "  The file does not exist — the test step never produced a log." >&2
    else
      echo "  The log was truncated before its summary. Failing closed: an" >&2
      echo "  unmeasurable run must never read as clean." >&2
    fi
    return 1
  fi

  local steps_total steps_failed
  steps_total="$(echo "$parsed" | cut -d' ' -f1)"
  steps_failed="$(echo "$parsed" | cut -d' ' -f2)"
  if [ "$steps_failed" -ne 0 ]; then
    echo "ok the run is red ($steps_total step(s) failed): its blocks ARE the"
    echo "   failure report, so this check stays silent"
    return 0
  fi

  report_offenders "$1" || return 1
  echo "ok green run: no logger line and no 'failed command:' block"
}

selftest() {
  local green warn raw red empty vendored
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELFTEST_TMP"; trap - RETURN' RETURN
  : >"$SELFTEST_TMP/allow"

  green="$SELFTEST_TMP/green.log"
  cat >"$green" <<'LOG'
[test] mod_tests split into 8 shard(s) from 5114 scanned test names
Build Summary: 28/28 steps succeeded; 4987/4991 tests passed (4 skipped)
LOG
  check_log "$green" >/dev/null || { echo "selftest: a clean green log was rejected"; return 1; }

  warn="$SELFTEST_TMP/warn.log"
  cat >"$warn" <<'LOG'
test
+- run test w
[default] (warn): tasks_move: stamp last_human_touched_at failed (non-fatal): PrepareFailed
failed command: ./.zig-cache/o/8804c/test --cache-dir=./.zig-cache --listen=-
Build Summary: 28/28 steps succeeded; 4987/4991 tests passed
LOG
  if check_log "$warn" >/dev/null 2>&1; then
    echo "selftest: a green run with a warn block was accepted"; return 1
  fi

  raw="$SELFTEST_TMP/raw.log"
  cat >"$raw" <<'LOG'
test
+- run test w
!! refusing fixture git: GIT_DIR is set !!
failed command: ./.zig-cache/o/b28db/test --listen=-
Build Summary: 28/28 steps succeeded; 4987/4991 tests passed
LOG
  if check_log "$raw" >/dev/null 2>&1; then
    echo "selftest: a green run with a raw fixture print was accepted"; return 1
  fi

  # A red run prints exactly those blocks, and is exempt.
  red="$SELFTEST_TMP/red.log"
  cat >"$red" <<'LOG'
test
+- run test 2 pass, 1 fail (3 total)
error: 'root.test.beta FAILS on purpose' failed:
       expected 1, found 2
failed command: ./.zig-cache/o/9c04f/test --listen=-
Build Summary: 1/3 steps succeeded (1 failed); 2/3 tests passed (1 failed)
LOG
  check_log "$red" >/dev/null || { echo "selftest: a red log was rejected"; return 1; }

  # Truncated: the unmeasurable path must fail closed, not read as clean.
  empty="$SELFTEST_TMP/empty.log"
  : >"$empty"
  if check_log "$empty" >/dev/null 2>&1; then
    echo "selftest: an unmeasurable log was accepted"; return 1
  fi

  # An allow entry admits exactly the lines it names, and nothing else.
  vendored="$SELFTEST_TMP/vendored.log"
  cat >"$vendored" <<'LOG'
test
+- run test w
[default] (warn): curl_easy_perform failed: CouldntConnect
failed command: ./.zig-cache/o/aaa/test --listen=-
Build Summary: 28/28 steps succeeded; 4987/4991 tests passed
LOG
  printf '%s\n' 'run test w$' 'failed command: ' 'curl_easy_perform failed' >"$ALLOW_FILE"
  check_log "$vendored" >/dev/null || { echo "selftest: --allow did not admit its lines"; return 1; }
  : >"$ALLOW_FILE"
  if check_log "$vendored" >/dev/null 2>&1; then
    echo "selftest: --allow leaked past its own patterns"; return 1
  fi

  # A raw print with no log prefix (the Windows pseudoconsole fallback) is not a
  # shape the scan knows; it is caught because it sits inside a `… w` block.
  unprefixed="$SELFTEST_TMP/unprefixed.log"
  cat >"$unprefixed" <<'LOG'
test
+- test mod_tests shard 2/2 (3265 tests) w
terminal: this host's pseudoconsole never produced a byte; using the pipe backend instead
failed command: PATH="C:/vcpkg"
Build Summary: 14/14 steps succeeded; 4798/4798 tests passed
LOG
  unprefixed_report="$(check_log "$unprefixed" 2>&1 || true)"
  check_log "$unprefixed" >/dev/null 2>&1 && { echo "selftest: an unprefixed block line was accepted"; return 1; }
  case "$unprefixed_report" in
    *"pseudoconsole never produced a byte"*) ;;
    *) echo "selftest: the report did not quote the unprefixed line"; return 1 ;;
  esac

  # Windows CI writes CRLF; a `<step> w` header must still be recognised.
  crlf="$SELFTEST_TMP/crlf.log"
  printf 'test\r\n+- test mod_tests shard 2/2 (3265 tests) w\r\nterminal: pipe backend instead\r\nfailed command: PATH="C:/vcpkg"\r\nBuild Summary: 14/14 steps succeeded; 4798/4798 tests passed\r\n' >"$crlf"
  check_log "$crlf" >/dev/null 2>&1 && { echo "selftest: a CRLF block was accepted"; return 1; }

  # A Windows `failed command:` is 4 KB of PATH; the report must stay readable.
  long="$SELFTEST_TMP/long.log"
  {
    printf 'test\n+- run test w\nfailed command: PATH="'
    head -c 4000 /dev/zero | tr '\0' 'x'
    printf '"\nBuild Summary: 28/28 steps succeeded; 4987/4991 tests passed\n'
  } >"$long"
  long_report="$(check_log "$long" 2>&1 || true)"
  check_log "$long" >/dev/null 2>&1 && { echo "selftest: a 4 KB failed-command line was accepted"; return 1; }
  longest="$(printf '%s\n' "$long_report" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  [ "$longest" -le 220 ] || { echo "selftest: the report echoed a $longest-byte line"; return 1; }

  echo "ok selftest: clean, warn block, raw print, red run, unmeasurable, allow hit, allow miss, unprefixed block line reported, CRLF block reported, 4 KB line reported short"
}

main() {
  local mode="" summary="" run_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --summary) mode=summary; summary="$2"; shift 2 ;;
      --run) mode=run; shift ;;
      --selftest) mode=selftest; shift ;;
      --allow) printf '%s\n' "$2" >>"$ALLOW_FILE"; shift 2 ;;
      --) shift; run_args=("$@"); break ;;
      *) echo "x unknown argument '$1' (see the usage in this file's header)" >&2; exit 2 ;;
    esac
  done

  case "$mode" in
    selftest) selftest ;;
    summary)
      [ -n "$summary" ] || { echo "x --summary needs a path" >&2; exit 2; }
      check_log "$summary"
      ;;
    run)
      RUN_LOG="$(mktemp)"
      local status=0
      ( cd "$REPO_ROOT" && zig build test --summary all "${run_args[@]}" ) 2>&1 | tee "$RUN_LOG"
      status="${PIPESTATUS[0]}"
      if [ "$status" -ne 0 ]; then
        echo "x 'zig build test' itself failed (exit $status): its own log is the" >&2
        echo "  report, so this check has nothing to add. Full log: $RUN_LOG" >&2
        exit 1
      fi
      check_log "$RUN_LOG"
      ;;
    *)
      echo "x one of --summary, --run, --selftest is required" >&2
      exit 2
      ;;
  esac
}

main "$@"
