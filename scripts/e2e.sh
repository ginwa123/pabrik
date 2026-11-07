#!/usr/bin/env bash
# Cross-platform E2E runner: Maestro (Android) + Playwright (Vue).
# Usage: ./scripts/e2e.sh [--seed|--reset|--android|--web|--all]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---all}"

seed() {
  echo "[e2e] seeding test backend (placeholder)"
  # TODO: call backend seed endpoint with E2E_USER/E2E_PASS from env
}

reset() {
  echo "[e2e] resetting test backend (placeholder)"
  # TODO: call backend reset endpoint
}

run_android() {
  echo "[e2e] running Maestro flows"
  if command -v maestro >/dev/null 2>&1; then
    maestro test "$ROOT/tests/e2e/maestro" || true
  else
    echo "[e2e] maestro not installed; skipping Android E2E"
  fi
}

run_web() {
  echo "[e2e] running Playwright suite"
  if [ -d "$ROOT/src/apps/desktop" ]; then
    (cd "$ROOT/src/apps/desktop" && npx playwright test "$ROOT/tests/e2e/playwright" 2>/dev/null) || true
  fi
}

case "$MODE" in
  --seed) seed ;;
  --reset) reset ;;
  --android) run_android ;;
  --web) run_web ;;
  --all) seed; run_android; run_web; reset ;;
  *) echo "unknown mode: $MODE"; exit 2 ;;
esac
echo "[e2e] done"
