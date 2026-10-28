#!/usr/bin/env bash
# Boot pabrik on the postgres backend, then prove the two things a sqlite-only
# tree could never prove: every migration applied, and full text search answers.
#
# Env:
#   PABRIK_DATABASE_CONNINFO  postgres conninfo (required)
#   PORT                      port to boot on (default 8080)
#   PABRIK_BIN                binary to run (default: the one zig build installed)
set -uo pipefail

CONN="${PABRIK_DATABASE_CONNINFO:?set PABRIK_DATABASE_CONNINFO to a postgres conninfo}"
PORT="${PORT:-8080}"
BIN="${PABRIK_BIN:-}"
if [ -z "$BIN" ]; then
  for candidate in zig-out/bin/pabrik zig-out/bin/pabrikcore-linux-x86_64; do
    [ -x "$candidate" ] && BIN="$candidate" && break
  done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "::error::no pabrik binary found (looked for zig-out/bin/pabrik)"
  exit 1
fi

fail() {
  echo "::error::$1"
  echo "--- boot log ---"
  tail -n 60 "$LOG"
  exit 1
}

# The highest version the tree registers: the smoke test stays correct when a
# migration is added, instead of pinning a number that goes stale.
EXPECTED_MAX="$(grep -ho 'pub const version: u32 = [0-9]*' src/migrations/migration_*.zig |
  grep -o '[0-9]*$' | sort -n | tail -n 1)"
if [ -z "$EXPECTED_MAX" ]; then
  echo "::error::could not read the highest migration version from src/migrations"
  exit 1
fi

HOME_DIR="$(mktemp -d)"
if [ -f "$HOME/.pgpass" ]; then
  install -m 600 "$HOME/.pgpass" "$HOME_DIR/.pgpass"
fi
export HOME="$HOME_DIR"
LOG="$(mktemp)"

"$BIN" --database=postgres --database-conninfo="$CONN" --port "$PORT" >"$LOG" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  grep -q 'Agent is ready to serve' "$LOG" && break
  if grep -q 'compiled with the sqlite backend only' "$LOG"; then
    fail "$BIN was built without the postgres backend; rebuild with -Ddb_used=sqlite,postgres"
  fi
  kill -0 "$pid" 2>/dev/null || fail "the server exited before it was ready"
  sleep 1
done
grep -q 'Agent is ready to serve' "$LOG" || fail "the server never reported it was ready"

grep -q 'database: backend=postgres' "$LOG" || fail "the boot line does not name the postgres backend"
if grep -qE '^error: ExecuteFailed|failed to run migrations' "$LOG"; then
  fail "a migration failed on postgres"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")"
[ "$code" = "200" ] || fail "/health answered $code, not 200"
echo "ok: the server booted on postgres and /health answers 200"

command -v psql >/dev/null || fail "psql is not installed; the assertions below need the postgres client"
reached="$(psql "$CONN" -tAqc 'SELECT max(version) FROM schema_migrations' 2>/dev/null)"
if [ "$reached" != "$EXPECTED_MAX" ]; then
  fail "migrations reached $reached, expected $EXPECTED_MAX"
fi
applied="$(psql "$CONN" -tAqc 'SELECT count(*) FROM schema_migrations' 2>/dev/null)"
echo "ok: $applied migrations applied, the highest is $reached"

indexes="$(psql "$CONN" -tAqc \
  "SELECT count(*) FROM pg_indexes WHERE indexname IN ('idx_llm_history_fts', 'idx_agent_memories_fts')" 2>/dev/null)"
if [ "$indexes" != "2" ]; then
  fail "expected 2 full text indexes, found $indexes"
fi
echo "ok: both full text indexes exist (idx_llm_history_fts, idx_agent_memories_fts)"

psql "$CONN" -q <<'SQL' 2>/dev/null
DELETE FROM llm_history WHERE id = 'smoke_fts_1';
INSERT INTO llm_history (id, session_id, model, response_content, role, created_iso)
VALUES ('smoke_fts_1', 'smoke_session', 'smoke', 'a smokecheckterm appears in this stored message', 'assistant', '2026-01-02 03:04:05');
SQL

# The same expression `searchMessagesFts` builds: to_tsquery over the tokens,
# ts_headline for the bracketed snippet, negative rank so ascending is best.
snippet="$(psql "$CONN" -tAqc "
  SELECT ts_headline('simple'::regconfig, COALESCE(h.response_content, ''), q.tsq,
                      'StartSel=[, StopSel=], MaxWords=10, MinWords=3')
  FROM llm_history h, to_tsquery('simple'::regconfig, 'smokecheckterm') AS q(tsq)
  WHERE to_tsvector('simple'::regconfig, COALESCE(h.response_content, '')) @@ q.tsq" 2>/dev/null)"
case "$snippet" in
  *"[smokecheckterm]"*) echo "ok: full text search found the row and marked the term: $snippet" ;;
  *) fail "full text search returned '$snippet', which does not mark the searched term" ;;
esac

hits="$(psql "$CONN" -tAqc "
  SELECT count(*) FROM llm_history h, to_tsquery('simple'::regconfig, 'absentterm') AS q(tsq)
  WHERE to_tsvector('simple'::regconfig, COALESCE(h.response_content, '')) @@ q.tsq" 2>/dev/null)"
[ "$hits" = "0" ] || fail "a term that appears nowhere matched $hits rows"
echo "ok: a term that appears nowhere matches no row"
