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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

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
  local out
  out="$(rg -U -n --no-heading 'catch[[:space:]]+unreachable\b' src/ 2>/dev/null || true)"
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

  mkdir -p "$tmp/src"

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

  echo "selftest: lint-no-catch-unreachable"

  # `set -e` would abort the whole selftest the first time a fixture
  # correctly fails to match, so every probe is wrapped in an `if`.
  probe() { # probe <file> -> prints 0 if the idiom is present, 1 if not
    if rg -U -q 'catch[[:space:]]+unreachable\b' "$1" 2>/dev/null; then
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
    if ! out="$(scan)"; then
      echo "x 'catch unreachable' is banned — see CODING_STANDARDS.md" >&2
      echo "  Replace each site with 'catch @panic(\"<what failed>\")'." >&2
      echo >&2
      printf '%s\n' "$out" | while IFS= read -r hit; do
        echo "  $hit" >&2
      done
      exit 1
    fi
    echo "ok no 'catch unreachable' under src/"
    ;;
  *)
    echo "usage: $0 [--selftest]" >&2
    exit 2
    ;;
esac
