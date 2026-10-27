#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: ci-docker-smoke.sh IMAGE [PORT] [WANT_BACKEND]}"
port="${2:-8080}"
want_backend="${3:-}"
name="pabrik-docker-smoke-$$"
health_file="$(mktemp)"

trap 'status=$?; if [ "$status" -ne 0 ]; then docker logs "$name" 2>&1 || true; fi; docker rm -f "$name" >/dev/null 2>&1 || true; rm -f "$health_file"; exit "$status"' EXIT

echo "→ docker run ${image} (in-container port ${port})"
# shellcheck disable=SC2086
docker run -d --name "$name" ${RUN_ARGS:-} "$image" --no-static-dir --port "$port" >/dev/null

served=0
for _ in $(seq 1 90); do
    if docker exec "$name" curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >"$health_file" 2>/dev/null; then
        served=1
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" != "true" ]; then
        echo "✗ the container exited before it answered /health" >&2
        exit 1
    fi
    sleep 1
done

if [ "$served" -ne 1 ]; then
    echo "✗ /health did not answer inside the container on port ${port} within 90s" >&2
    exit 1
fi

body="$(cat "$health_file")"
echo "→ GET /health (inside the container): ${body}"

case "$body" in
    *'"status":"ok"'*) ;;
    *)
        echo "✗ /health did not report a status of ok" >&2
        exit 1
        ;;
esac

logs="$(docker logs "$name" 2>&1 || true)"
printf '%s\n' "$logs" | grep -E 'database: backend=|runtime mode:|Agent is ready to serve' || true

if [ -n "$want_backend" ]; then
    if ! printf '%s\n' "$logs" | grep -q "database: backend=${want_backend} "; then
        echo "✗ the boot log does not name backend=${want_backend}" >&2
        exit 1
    fi
    echo "✓ boot log names backend=${want_backend}"
fi

if [ -n "${EXPECT_DB_FILE:-}" ]; then
    if ! docker exec "$name" test -s "$EXPECT_DB_FILE"; then
        echo "✗ expected database file ${EXPECT_DB_FILE} is missing or empty" >&2
        exit 1
    fi
    echo "✓ ${EXPECT_DB_FILE} exists in the container"
fi

if [ "${HOST_CHECK:-0}" = "1" ]; then
    echo "→ GET /health from the host"
    curl -fsS --max-time 5 "http://127.0.0.1:${port}/health"
    echo
    echo "✓ the host reaches the server on port ${port}"
fi

echo "✓ ${image} serves /health"
