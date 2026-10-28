#!/usr/bin/env bash
# Ban `catch unreachable` in Zig source.
#
# WHY THIS EXISTS
# ---------------
# `catch unreachable` is the most dangerous error-handling idiom in Zig,
# and it is dangerous in a way that is invisible in the build everyone
# actually runs:
#
#   * In Debug/ReleaseSafe it panics with `reached unreachable code` —
#     no file, no line, no error name, no hint about WHICH catch fired.
#     The crash triage doc (AGENTS.md, "Crash Triage") exists because
#     that message has cost this repo real hours.
#   * In ReleaseFast it is UNDEFINED BEHAVIOUR. The compiler is free to
#     assume the error branch never happens and delete the check, so the
#     failure surfaces later and somewhere else entirely — a wild write,
#     a truncated response, a hang. `ReleaseFast` skips
#     `recoverableOsBugDetected` for exactly this reason.
#
# The sanctioned replacement is `catch @panic("...")`: a real panic in
# EVERY build mode, with a message the author wrote. It is a drop-in
# swap — `@panic` returns `noreturn`, which coerces to the same result
# type `unreachable` did, so no call site changes.
#
# WHAT IS NOT BANNED
# ------------------
#   * `unreachable` as a `switch` else / prong — that is the compiler
#     proving exhaustiveness, and it is correct.
#   * `@panic("...")` directly — that IS the sanctioned form.
#   * `catch @panic(...)` — the sanctioned form.
# Only the exact `catch unreachable` token pair is rejected.
#
# COMMENTS ARE SCANNED TOO, deliberately. A commented-out
# `catch unreachable` is a trap for the next person to uncomment it, and
# a comment that names the idiom is an invitation to paste it. Reword
# the comment instead of asking for an exemption.
#
# USAGE
#   lint-no-catch-unreachable.sh          -> scan src/, exit 1 on any hit
#   lint-no-catch-unreachable.sh --selftest -> run against fixtures
#
# REQUIRES `rg` (ripgrep) on PATH. The check is a hard failure, not a
# skip: a lint that cannot run must never report the tree clean, because
# "clean" is the one answer that lets a violation merge. This is not
# hypothetical — the first version of this script had exactly that bug
# (`2>/dev/null || true` swallowed "rg: command not found" into a pass)
# and the selftest below is what caught it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "x ripgrep (rg) not found on PATH -- cannot scan, so this is a" >&2
  echo "  FAILURE, not a pass. Install ripgrep, or add it to the job" >&2
  echo "  that runs this script." >&2
  exit 1
fi

# ── The scan ───────────────────────────────────────────────────────────
#
# `catch` followed by whitespace then `unreachable`, with a word boundary
# after it so `catch unreachableFoo` is not a false positive. The pattern
# is deliberately narrow: it matches the idiom and nothing else, so the
# lint has no baseline and no allowlist to rot.
# `-U` (multiline) is load-bearing: rg is line-oriented by default, so
# without it a legal `catch` / newline / `unreachable` split — which
# `zig fmt` will happily produce on a long line — slips through.
scan() {
  local out rc=0
  # Capture rg's stderr instead of discarding it: "command not found",
  # a permission error and a genuine no-match all look like an empty
  # stdout, and only one of them means the tree is clean. `|| rc=$?` and
  # never a `set +e`/`set -e` toggle: those are shell-GLOBAL, and the
  # `set -e` that closed the old toggle was still armed on the way out, so
  # `return 1` killed the caller before it printed a single violation.
  out="$(rg -U -n --no-heading 'catch[[:space:]]+unreachable\b' src/ 2>&1)" || rc=$?
  # rg exits 0 = matches found, 1 = no matches, >=2 = rg itself failed.
  if [ "$rc" -ge 2 ]; then
    echo "x the scan could not run (rg exit $rc):" >&2
    printf '%s\n' "$out" >&2
    return 2
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

# ── Selftest ──────────────────────────────────────────────────────────
#
# The scan is the whole product, so a scan that has stopped matching is a
# silent outage — the same argument ci-change-filter.sh makes for its own
# --selftest. Fixtures live in a tmpdir and are removed on exit.
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

  mkdir -p "$tmp/src" "$tmp/emptybin"

  # 1. A clean file must pass.
  cat > "$tmp/src/clean.zig" <<'EOF'
const std = @import("std");
pub fn f() !void {
    const x = g() catch @panic("g failed");
    _ = x;
}
EOF

  # 2. The banned idiom must be caught.
  cat > "$tmp/src/banned.zig" <<'EOF'
const std = @import("std");
pub fn f() !void {
    const x = g() catch unreachable;
    _ = x;
}
EOF

  # 3. `unreachable` in a switch else must NOT be caught.
  cat > "$tmp/src/switch_else.zig" <<'EOF'
pub fn f(x: u8) u8 {
    return switch (x) {
        0 => 1,
        else => unreachable,
    };
}
EOF

  # 4. A bare `@panic` must NOT be caught.
  cat > "$tmp/src/panic.zig" <<'EOF'
pub fn f() noreturn {
    @panic("no");
}
EOF

  # 5. The idiom inside a comment IS caught — a commented-out
  #    `catch unreachable` is a trap for whoever uncomments it.
  cat > "$tmp/src/comment.zig" <<'EOF'
// self.mutex.lock(self.io) catch unreachable;
pub fn f() void {}
EOF

  # 6. `catch unreachableFoo` must NOT be caught (word boundary).
  cat > "$tmp/src/boundary.zig" <<'EOF'
pub fn f() void {
    _ = g() catch unreachableHelper;
}
EOF

  # 7. A tab between catch and unreachable must be caught.
  printf 'pub fn f() void {\n\t_ = g() catch\tunreachable;\n}\n' > "$tmp/src/tabbed.zig"

  # 8. A newline between catch and unreachable must be caught.
  printf 'pub fn f() void {\n\t_ = g() catch\n\t    unreachable;\n}\n' > "$tmp/src/newline.zig"

  # 9. THE REGRESSION GUARD. With no `rg` on PATH the scanner must FAIL,
  #    not report the tree clean. The first version of this script had the
  #    opposite behaviour — `2>/dev/null || true` turned
  #    "rg: command not found" into "no matches" — and it passed CI on a
  #    runner that ships no ripgrep. A lint that cannot run must never
  #    answer "clean", because "clean" is the one answer that merges.
  #
  # Invoked via an absolute bash path, not `$0`: the shebang needs `env`
  # on PATH, and a PATH with no rg has no `env` either, so `$0` would die
  # with 127 before reaching the check we are actually testing.
  local rc_norg bash_abs
  bash_abs="$(command -v bash)"
  rc_norg=0
  PATH="$tmp/emptybin" "$bash_abs" "$0" >/dev/null 2>&1 || rc_norg=$?

  echo "selftest: lint-no-catch-unreachable"

  # `set -e` would abort the whole selftest the first time a fixture
  # correctly fails to match, so every probe is wrapped in an `if`.
  probe() { # probe <file> -> prints 0 if the idiom is present, 1 if not
    local rc=0
    rg -U -q 'catch[[:space:]]+unreachable\b' "$1" >/dev/null 2>&1 || rc=$?
    # >=2 means rg itself failed, which must NOT read as "no match".
    if [ "$rc" -ge 2 ]; then
      echo 2
    elif [ "$rc" -eq 0 ]; then
      echo 0
    else
      echo 1
    fi
  }

  local rc_clean rc_banned rc_switch rc_panic rc_comment rc_boundary rc_tab rc_newline
  rc_clean="$(probe "$tmp/src/clean.zig")"
  rc_banned="$(probe "$tmp/src/banned.zig")"
  rc_switch="$(probe "$tmp/src/switch_else.zig")"
  rc_panic="$(probe "$tmp/src/panic.zig")"
  rc_comment="$(probe "$tmp/src/comment.zig")"
  rc_boundary="$(probe "$tmp/src/boundary.zig")"
  rc_tab="$(probe "$tmp/src/tabbed.zig")"
  rc_newline="$(probe "$tmp/src/newline.zig")"

  check "clean file passes"            1 "$rc_clean"
  check "banned idiom is caught"       0 "$rc_banned"
  check "switch else unreachable ok"   1 "$rc_switch"
  check "bare @panic ok"               1 "$rc_panic"
  check "commented-out idiom is caught" 0 "$rc_comment"
  check "unreachableFoo ok"            1 "$rc_boundary"
  check "tab-separated is caught"      0 "$rc_tab"
  check "newline-separated is caught"  0 "$rc_newline"
  check "missing rg FAILS (not a pass)" 1 "$rc_norg"

  # 10. THE REPORTING GUARD. A run that finds a violation must NAME it: on
  #     2026-10-28 `main` failed this lint with a green selftest and a bare
  #     exit 1, and the whole triage started from a log holding no file:line.
  #     Pin both halves — the status AND the location.
  local self_path
  self_path="$REPO_ROOT/scripts/$(basename "${BASH_SOURCE[0]}")"
  mkdir -p "$tmp/repo/scripts"
  cp "$self_path" "$tmp/repo/scripts/"
  cp -r "$tmp/src" "$tmp/repo/src"
  local rc_report report
  rc_report=0
  report="$("$bash_abs" "$tmp/repo/scripts/$(basename "$self_path")" 2>&1)" || rc_report=$?
  check "a violation exits 1"          1 "$rc_report"
  if printf '%s\n' "$report" | grep -q 'banned\.zig:3'; then
    echo "  ok   a violation names its file:line"
  else
    echo "  FAIL a violation names its file:line (got: $report)"
    failures=$((failures + 1))
  fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest: $failures failure(s)"
    return 1
  fi
  echo "selftest: all checks passed"
  return 0
}

# ── Entry point ────────────────────────────────────────────────────────
case "${1:-}" in
  --selftest)
    selftest
    ;;
  "")
    # `scan` prints its hits on stdout and its diagnostics on stderr, so
    # capture the two streams separately: a broken scan must not have its
    # error text mistaken for a list of violations.
    hits="$(mktemp)"
    diag="$(mktemp)"
    # shellcheck disable=SC2064  # expand the paths NOW, not at trap time
    trap "rm -f '$hits' '$diag'" EXIT
    # `|| rc=$?` keeps `set -e` from exiting the script on a hit before
    # `rc` is read, so a violation is always named.
    rc=0
    scan >"$hits" 2>"$diag" || rc=$?
    if [ "$rc" -eq 2 ]; then
      cat "$diag" >&2
      exit 1
    fi
    if [ "$rc" -eq 1 ]; then
      echo "x 'catch unreachable' is banned — see CODING_STANDARDS.md" >&2
      echo "  Replace each site with 'catch @panic(\"<what failed>\")'." >&2
      echo >&2
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "  $hit" >&2
      done <"$hits"
      exit 1
    fi
    echo "ok no 'catch unreachable' under src/"
    ;;
  *)
    echo "usage: $0 [--selftest]" >&2
    exit 2
    ;;
esac
