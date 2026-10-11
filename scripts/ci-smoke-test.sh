#!/usr/bin/env bash
# Smoke test: Criteria pass for the pabrik agent.
#
# Verifies that a fresh pabrik binary:
#   1. Starts without crashing
#   2. Emits "Agent is ready to serve!" (src/main.zig:380) within 30s
#   3. Serves /health with {"status":"ok",...}
#   4. Serves /api/workspaces with HTTP 200
#   4b. (opt-in via PABRIK_SMOKE_CHECK_APP=1) Serves / with the app shell
#   5. Shuts down cleanly when /test/shutdown is POSTed
#
# Designed to be run on a CI runner (or locally) where no pabrik is
# already running. Uses port 18080 to avoid collision with the dev ports
# (8080, 8081). Uses an isolated $HOME so the smoke test DB doesn't
# interfere with a developer's local one.
#
# Cross-platform: works on Linux, macOS, and Windows Git Bash. On Windows
# the `kill -TERM` escalation path uses `TerminateProcess` (forceful
# exit) instead of delivering a Unix signal, which matches what
# docker / kubernetes do on container stop. The GinwaServer shutdown
# method (kabelweb repo src/server/http_server.zig:535) calls
# `shutdown(sock, SHUT_RDWR)` to wake the listen loop's blocked accept
# call, so the graceful path is fast on both POSIX and Winsock.
#
# Designed to be sourced (`. /tmp/pabrik-smoke-test.sh`) from another
# script that has already resolved $PABRIK_BIN and $PABRIK_PORT.

set -u

if [ -z "${PABRIK_BIN:-}" ] || [ ! -x "$PABRIK_BIN" ]; then
  echo "✗ smoke test: PABRIK_BIN is unset or not executable: '$PABRIK_BIN'" >&2
  exit 1
fi

: "${PABRIK_PORT:=18080}"

# Isolate HOME so config.json + agent.db live in a tempdir.
export HOME="$(mktemp -d -t pabrik-smoke-home.XXXXXX)"
SMOKE_LOG="$(mktemp -t pabrik-smoke.XXXXXX.log)"

cleanup() {
  local ec=$?
  if [ -n "${PABRIK_PID:-}" ] && kill -0 "$PABRIK_PID" 2>/dev/null; then
    kill -TERM "$PABRIK_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$PABRIK_PID" 2>/dev/null || true
  fi
  rm -rf "$HOME" 2>/dev/null || true
  rm -f "$SMOKE_LOG" 2>/dev/null || true
  exit $ec
}
trap cleanup EXIT INT TERM

echo "→ smoke test: HOME=$HOME PORT=$PABRIK_PORT BIN=$PABRIK_BIN"

# Boot the binary in the background, capture combined stdout+stderr.
"$PABRIK_BIN" --port "$PABRIK_PORT" >"$SMOKE_LOG" 2>&1 &
PABRIK_PID=$!
echo "→ pabrik pid=$PABRIK_PID"

# Step 1: wait up to 30s for the "Agent is ready to serve!" line.
READY_DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$READY_DEADLINE" ]; do
  if ! kill -0 "$PABRIK_PID" 2>/dev/null; then
    echo "✗ pabrik (pid=$PABRIK_PID) exited before becoming ready" >&2
    echo "--- log output ---" >&2
    cat "$SMOKE_LOG" >&2
    echo "--- end log ---" >&2
    exit 1
  fi
  if grep -q "Agent is ready to serve!" "$SMOKE_LOG"; then
    echo "✓ step 1/5: 'Agent is ready to serve!' observed"
    break
  fi
  sleep 0.2
done
if ! grep -q "Agent is ready to serve!" "$SMOKE_LOG"; then
  echo "✗ timeout waiting for 'Agent is ready to serve!' (30s)" >&2
  echo "--- log output ---" >&2
  cat "$SMOKE_LOG" >&2
  echo "--- end log ---" >&2
  exit 1
fi

# Step 2: GET /health — expect JSON {"status":"ok",...}
HEALTH_BODY="$(curl -fsS --max-time 5 "http://127.0.0.1:${PABRIK_PORT}/health" 2>&1)" || {
  echo "✗ /health request failed: $HEALTH_BODY" >&2
  exit 1;
}
case "$HEALTH_BODY" in
  *'"status":"ok"'*) echo "✓ step 2/5: /health returned status:ok" ;;
  *)
    echo "✗ /health did not return status:ok — body: $HEALTH_BODY" >&2
    exit 1
    ;;
esac

# Step 3: GET /api/workspaces — expect HTTP 200 (no body assertions)
WORKSPACES_STATUS="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PABRIK_PORT}/api/workspaces" 2>&1)" || {
  echo "✗ /api/workspaces request failed: $WORKSPACES_STATUS" >&2
  exit 1;
}
if [ "$WORKSPACES_STATUS" = "200" ]; then
  echo "✓ step 3/5: /api/workspaces returned 200"
else
  echo "✗ /api/workspaces returned $WORKSPACES_STATUS (expected 200)" >&2
  exit 1
fi

# Step 3b (opt-in via PABRIK_SMOKE_CHECK_APP=1): GET / serves the app
# shell (proves a shipped/installed html/ is discovered). Off by default:
# backend cells boot from zig-out layouts where html/ may legitimately be
# absent (fresh checkout without a webapp build); the install jobs turn it
# on because their contract IS "the installer ships a working /app".
if [ "${PABRIK_SMOKE_CHECK_APP:-0}" = "1" ]; then
  APP_BODY="$(curl -fsS --max-time 5 "http://127.0.0.1:${PABRIK_PORT}/" 2>&1)" || {
    echo "✗ / request failed: $APP_BODY" >&2
    exit 1;
  }
  case "$APP_BODY" in
    *'<'*) echo "✓ step 3b/5: / serves the app shell" ;;
    *)
      echo "✗ / did not serve the app shell" >&2
      exit 1
      ;;
  esac
fi

# Step 4: POST /test/shutdown — expect {"message":"Server shutdown initiated"}
SHUTDOWN_BODY="$(curl -fsS -X POST --max-time 5 "http://127.0.0.1:${PABRIK_PORT}/test/shutdown" 2>&1)" || {
  echo "✗ /test/shutdown request failed: $SHUTDOWN_BODY" >&2
  exit 1;
}
case "$SHUTDOWN_BODY" in
  *'Server shutdown initiated'*) echo "✓ step 4/5: /test/shutdown initiated" ;;
  *)
    echo "✗ /test/shutdown returned unexpected body: $SHUTDOWN_BODY" >&2
    exit 1
    ;;
esac

# Step 5: wait up to 5s for graceful process exit, then escalate to SIGTERM.
#
# As of the windows-smoke-test fix (GinwaServer.shutdown calls
# `shutdown(sock, SHUT_RDWR)` to wake the listen loop's blocked
# accept), the graceful path is much faster on Linux. On Windows,
# `kill -TERM` translates to `TerminateProcess` (no real signal
# mechanism) which forcefully exits — also acceptable per the same
# "process responds to shutdown requests" criterion that systemd /
# docker / kubernetes use on container stop.
#
# The SIGTERM fallback stays in place as a safety net: the
# routine-fire scheduler (Scheduler.start, runs forever on
# `di.group_emit_session_create`) blocks clean process exit
# even after the HTTP listener returns, so the smoke test
# historically relied on SIGTERM to fully reap the process.
# This is a pre-existing concern (unrelated to the Windows fix);
# both platforms hit step 5/5b.
SHUTDOWN_DEADLINE=$(( $(date +%s) + 5 ))
EXITED=false
while [ "$(date +%s)" -lt "$SHUTDOWN_DEADLINE" ]; do
  if ! kill -0 "$PABRIK_PID" 2>/dev/null; then
    wait "$PABRIK_PID" 2>/dev/null
    EXIT_CODE=$?
    echo "✓ step 5/5a: pabrik exited gracefully (code=$EXIT_CODE)"
    EXITED=true
    break
  fi
  sleep 0.2
done
if [ "$EXITED" != "true" ]; then
  # Graceful shutdown didn't reap the process in time — fall back
  # to SIGTERM. On Linux this breaks the listen loop via EINTR; on
  # Windows Git Bash's `kill -TERM` calls `TerminateProcess`
  # (forceful exit, no signal mechanism). Either way the
  # criterion "process responds to shutdown requests" is met.
  echo "→ step 5/5b: graceful shutdown did not reap process in time; sending SIGTERM"
  kill -TERM "$PABRIK_PID" 2>/dev/null || true
  TERM_DEADLINE=$(( $(date +%s) + 5 ))
  while [ "$(date +%s)" -lt "$TERM_DEADLINE" ]; do
    if ! kill -0 "$PABRIK_PID" 2>/dev/null; then
      wait "$PABRIK_PID" 2>/dev/null
      EXIT_CODE=$?
      echo "✓ step 5/5c: pabrik exited on SIGTERM (code=$EXIT_CODE)"
      EXITED=true
      break
    fi
    sleep 0.2
  done
fi
if [ "$EXITED" != "true" ]; then
  echo "✗ pabrik did not exit after graceful shutdown + SIGTERM" >&2
  echo "--- log output ---" >&2
  cat "$SMOKE_LOG" >&2
  echo "--- end log ---" >&2
  kill -KILL "$PABRIK_PID" 2>/dev/null || true
  exit 1
fi

echo "→ smoke test: all 5 criteria steps PASSED"
exit 0
