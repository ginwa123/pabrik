#!/usr/bin/env bash
# Wall-clock benchmark for the Playwright UI functional suite.
#
# WHY THIS EXISTS
# ---------------
# `zig build functional-test-ui` is the slowest gate a frontend change has to
# pass, and every attempt to speed it up so far has been argued from a hunch.
# This script turns the argument into a number: it runs the suite once, splits
# the wall clock into pytest's own setup/call/teardown buckets, and writes both
# a JSON record and a one-line table row. Two runs with different `--label`
# values are the before/after evidence a reviewer can re-derive.
#
# The split matters more than the total. A per-test harness boot shows up in
# `setup`; a cold Vite module graph shows up in `call` (the first `page.goto`
# pays the compile); a leaked child process shows up as `call` inflation on
# every test after it. Reading only the total cannot tell those apart.
#
# USAGE
#   scripts/bench-functional-ui.sh                       # whole suite, serial
#   scripts/bench-functional-ui.sh --label after -n 4    # extra pytest args
#   scripts/bench-functional-ui.sh --subset chatview_ui_test.py
#
# OUTPUT
#   $TMPDIR/pabrik/bench-functional-ui-<label>.log    full pytest log
#   $TMPDIR/pabrik/bench-functional-ui-<label>.json   the record
#   stdout                                            one table row
#
# Exit code is pytest's, so a red suite is a red benchmark.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LABEL="run"
TARGETS=()
PYTEST_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --subset) TARGETS+=("tests/functional_ui/$2"); shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    tests/*) TARGETS+=("$1"); shift ;;
    *) PYTEST_ARGS+=("$1"); shift ;;
  esac
done

PY="$ROOT/.venv-func/bin/python"
if [ ! -x "$PY" ]; then
  echo "bench-functional-ui: $PY not found; run 'zig build functional-test-ui' once to create the venv" >&2
  exit 2
fi

OUT_DIR="${TMPDIR:-/tmp}/pabrik"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/bench-functional-ui-$LABEL.log"
JSON="$OUT_DIR/bench-functional-ui-$LABEL.json"

if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("tests/functional_ui/")
fi

START_NS="$(date +%s%N)"
"$PY" -m pytest "${TARGETS[@]}" -q --tb=no -p no:cacheprovider --durations=0 \
  "${PYTEST_ARGS[@]}" >"$LOG" 2>&1
RC=$?
END_NS="$(date +%s%N)"

"$PY" - "$LOG" "$JSON" "$LABEL" "$RC" "$(( (END_NS - START_NS) / 1000000 ))" <<'PY'
import json
import re
import sys

log_path, json_path, label, rc, wall_ms = sys.argv[1:6]
text = open(log_path, encoding="utf-8", errors="replace").read()

summary = re.search(
    r"^=+ (?:(\d+) failed, )?(?:(\d+) passed)?(?:, (\d+) skipped)?(?:, (\d+) error)?.*? in ([\d.]+)s",
    text,
    re.MULTILINE,
)
passed = int(summary.group(2) or 0) if summary else 0
failed = int(summary.group(1) or 0) if summary else 0
skipped = int(summary.group(3) or 0) if summary else 0
errors = int(summary.group(4) or 0) if summary else 0
pytest_s = float(summary.group(5)) if summary else 0.0

buckets = {"setup": 0.0, "call": 0.0, "teardown": 0.0}
for value, phase in re.findall(r"^([\d.]+)s (setup|call|teardown)\s", text, re.MULTILINE):
    buckets[phase] += float(value)

executed = passed + failed + errors
record = {
    "label": label,
    "exit_code": int(rc),
    "wall_s": round(int(wall_ms) / 1000.0, 2),
    "pytest_s": round(pytest_s, 2),
    "tests": executed,
    "passed": passed,
    "failed": failed,
    "skipped": skipped,
    "errors": errors,
    "per_test_s": round(pytest_s / executed, 3) if executed else None,
    "setup_s": round(buckets["setup"], 2),
    "call_s": round(buckets["call"], 2),
    "teardown_s": round(buckets["teardown"], 2),
    "log": log_path,
}
with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(record, fh, indent=2)
    fh.write("\n")

print(
    f"{label:<12} {record['tests']:>4} tests  "
    f"{record['pytest_s']:>7.2f}s  "
    f"{record['per_test_s'] or 0:>6.3f}s/test  "
    f"setup {record['setup_s']:>6.2f}s  call {record['call_s']:>7.2f}s  "
    f"teardown {record['teardown_s']:>5.2f}s  "
    f"pass {passed} fail {failed} skip {skipped} err {errors}"
)
print(f"json: {json_path}")
PY

exit "$RC"
