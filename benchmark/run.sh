#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENGINE="${CONTAINER_ENGINE:-docker}"
IMAGE="${API_BENCH_IMAGE:-pabrik-api-bench:local}"
SERVER_NAME="${API_BENCH_SERVER_NAME:-pabrik-api-bench-server}"
PABRIK_BIN="${PABRIK_BIN:-$ROOT/zig-out/bin/pabrikcore-linux-x86_64}"
LOADGEN_BIN="${API_BENCH_LOADGEN:-$ROOT/zig-out/bin/api-bench}"
PORT="${API_BENCH_PORT:-18080}"
SCENARIOS="${API_BENCH_SCENARIOS:-all}"
SERVER_CPUSET="${API_BENCH_SERVER_CPUSET-0,1}"
CLIENT_CPUSET="${API_BENCH_CLIENT_CPUSET-2,3}"
SERVER_CPUS=2
CLIENT_CPUS=2
MEMORY_MB=2048
CLIENT_MEMORY_MB=1024
REQUESTS="${API_BENCH_REQUESTS:-2000}"
CONCURRENCY="${API_BENCH_CONCURRENCY:-8}"
WARMUP="${API_BENCH_WARMUP:-200}"
STRICT="${API_BENCH_STRICT:-0}"
MIN_SCALING="${API_BENCH_MIN_SCALING:-2.0}"
MAX_P99_MS="${API_BENCH_MAX_P99_MS:-5.0}"
MIN_RPS="${API_BENCH_MIN_RPS:-2000.0}"
PROFILE="${API_BENCH_PROFILE:-}"
OUT_DIR="${API_BENCH_OUT:-${TMPDIR:-/tmp}/pabrik-api-bench}"

die() {
  printf 'api-bench: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
benchmark/run.sh [selftest|image|run|spec]

  selftest   the harness unit tests (zig test), no container, no network
  image      build the load generator and the benchmark image
  run        build everything, then run the benchmark (default)
  spec       print the container spec this profile pins

environment:
  CONTAINER_ENGINE        docker (default) or podman
  PABRIK_BIN              server binary, default zig-out/bin/pabrikcore-linux-x86_64
  API_BENCH_OUT           directory for api-bench.json, api-bench.md, server.log
  API_BENCH_REQUESTS      requests per measured phase, default 2000
  API_BENCH_CONCURRENCY   the concurrency of the cN phase, default 8
  API_BENCH_SCENARIOS     comma list of scenarios, default all (health, messages, sessions, documents, documents-reorder, folder-search)
  API_BENCH_STRICT=1      a performance-gate miss fails the run
  API_BENCH_SERVER_CPUSET empty drops --cpuset-cpus and the profile becomes quota-2cpu
  API_BENCH_CLIENT_CPUSET empty drops --cpuset-cpus and the profile becomes quota-2cpu
USAGE
}

resolve_profile() {
  if [ -z "$PROFILE" ]; then
    if [ -n "$SERVER_CPUSET" ] && [ -n "$CLIENT_CPUSET" ]; then
      PROFILE="dedicated-2cpu"
    else
      PROFILE="quota-2cpu"
    fi
  fi
}

cpuset_args() {
  local server="$1" client="$2"
  CPUSET_SERVER_ARGS=()
  CPUSET_CLIENT_ARGS=()
  [ -n "$server" ] && CPUSET_SERVER_ARGS=(--cpuset-cpus "$server")
  [ -n "$client" ] && CPUSET_CLIENT_ARGS=(--cpuset-cpus "$client")
  return 0
}

strict_args() {
  STRICT_ARGS=()
  [ "${1:-0}" = "1" ] && STRICT_ARGS=(--strict)
  return 0
}

spec() {
  cat <<SPEC
profile          $PROFILE
engine           $ENGINE
image            $IMAGE
server binary    $PABRIK_BIN
load generator   $LOADGEN_BIN
scenarios        $SCENARIOS on 127.0.0.1:$PORT (health = /health, messages = /api/session/bench/messages, sessions = /api/llm/session?limit=50,
                 documents = GET /api/workspaces/bench-docs/documents, documents-reorder = PATCH .../documents/reorder,
                 folder-search = GET /api/system/folder?action=search over the image's deep/flat trees)
server container --cpus $SERVER_CPUS --cpuset-cpus ${SERVER_CPUSET:-none} --memory ${MEMORY_MB}m --network none
client container --cpus $CLIENT_CPUS --cpuset-cpus ${CLIENT_CPUSET:-none} --memory ${CLIENT_MEMORY_MB}m --network container:$SERVER_NAME
phases           c1 (concurrency 1) and cN (concurrency $CONCURRENCY), $REQUESTS requests each ($WARMUP warmup; a scenario may set its own)
gate             min scaling $MIN_SCALING, p99 at c1 <= $MAX_P99_MS ms, rps at cN >= $MIN_RPS
strict           $STRICT
output           $OUT_DIR
SPEC
}

selftest() {
  command -v zig >/dev/null 2>&1 || die "zig is required for the selftest"
  ( cd "$ROOT" && zig test benchmark/api_bench.zig )
}

check_engine() {
  command -v "$ENGINE" >/dev/null 2>&1 || die "container engine not found: $ENGINE (set CONTAINER_ENGINE=docker or podman)"
  "$ENGINE" info >/dev/null 2>&1 || die "$ENGINE cannot reach a running daemon"
}

check_binary() {
  [ -f "$PABRIK_BIN" ] || die "server binary missing: $PABRIK_BIN (run: zig build install:linux -Doptimize=ReleaseFast -Dno-webapp-rebuild)"
  [ -x "$PABRIK_BIN" ] || die "server binary is not executable: $PABRIK_BIN"
}

check_cpus() {
  local available set id
  [ -n "$SERVER_CPUSET" ] && [ -n "$CLIENT_CPUSET" ] || return 0
  available="$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN)"
  [ "$available" -ge 4 ] || die "this profile needs 4 logical cpus, the machine reports $available"
  for set in "$SERVER_CPUSET" "$CLIENT_CPUSET"; do
    local IFS=,
    for id in $set; do
      [ "$id" -lt "$available" ] || die "cpuset member $id does not exist (only $available cpus)"
    done
  done
}

build_loadgen() {
  command -v zig >/dev/null 2>&1 || die "zig is required to build the load generator"
  printf 'api-bench: building the load generator into %s\n' "$LOADGEN_BIN"
  ( cd "$ROOT" && zig build-exe benchmark/api_bench.zig -O ReleaseFast -target x86_64-linux-musl -femit-bin="$LOADGEN_BIN" )
}

# The `folder-search` scenario's two trees: the same 512 matching files, one
# spread over 256 leaf directories and one over 8. Built here rather than by the
# server, so the benchmark writes nothing at run time and the route under test
# keeps its only job.
make_folder_tree() {
  local dest="$1"
  local deep="$dest/deep" flat="$dest/flat"
  local top mid leaf n index=0
  mkdir -p "$deep" "$flat"
  for top in $(seq 0 7); do
    for mid in $(seq 0 7); do
      for leaf in $(seq 0 3); do
        mkdir -p "$deep/a$top/b$mid/c$leaf"
        for n in 0 1; do
          : > "$deep/a$top/b$mid/c$leaf/component_$index.txt"
          index=$((index + 1))
        done
      done
    done
  done
  for top in $(seq 0 7); do
    mkdir -p "$flat/f$top"
    for n in $(seq 0 63); do
      : > "$flat/f$top/component_$index.txt"
      index=$((index + 1))
    done
  done
  for tree in "$deep" "$flat"; do
    printf '*.ignored\n' > "$tree/.gitignore"
    for n in $(seq 0 7); do : > "$tree/junk_$n.ignored"; done
  done
}

build_image() {
  local stage
  stage="$(mktemp -d)"
  cp "$PABRIK_BIN" "$stage/pabrik"
  cp "$LOADGEN_BIN" "$stage/api-bench"
  make_folder_tree "$stage/folder-tree"
  printf 'api-bench: building %s from %s\n' "$IMAGE" "$stage"
  if ! "$ENGINE" build -f "$ROOT/benchmark/Containerfile" -t "$IMAGE" "$stage"; then
    rm -rf "$stage"
    die "image build failed"
  fi
  rm -rf "$stage"
}

server_running() {
  [ -n "$("$ENGINE" ps --filter "name=^${SERVER_NAME}$" --format '{{.Names}}' 2>/dev/null)" ]
}

cleanup() {
  "$ENGINE" rm -f "${SERVER_NAME}-client" >/dev/null 2>&1 || true
  if [ -n "${SERVER_NAME:-}" ]; then
    "$ENGINE" logs "$SERVER_NAME" > "$OUT_DIR/server.log" 2>&1 || true
    "$ENGINE" rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
  fi
}

run_bench() {
  local rc digest client
  mkdir -p "$OUT_DIR"
  "$ENGINE" rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
  trap cleanup EXIT INT TERM

  digest="$(sha256sum "$PABRIK_BIN" | cut -d' ' -f1)"
  printf 'api-bench: server binary sha256 %s\n' "$digest"

  "$ENGINE" run -d \
    --name "$SERVER_NAME" \
    --network none \
    --cpus "$SERVER_CPUS" \
    "${CPUSET_SERVER_ARGS[@]}" \
    --memory "${MEMORY_MB}m" \
    --memory-swap "${MEMORY_MB}m" \
    --pids-limit 512 \
    --ulimit nofile=65536:65536 \
    --tmpfs /pabrik-home:rw,exec,size=256m \
    --env PABRIK_BENCH_SEED=1 \
    "$IMAGE" /opt/pabrik/pabrik --port "$PORT" >/dev/null

  sleep 0.5
  server_running || die "the server container exited during start-up; see $OUT_DIR/server.log"

  client="${SERVER_NAME}-client"
  "$ENGINE" rm -f "$client" >/dev/null 2>&1 || true

  set +e
  "$ENGINE" run \
    --name "$client" \
    --network "container:$SERVER_NAME" \
    --cpus "$CLIENT_CPUS" \
    "${CPUSET_CLIENT_ARGS[@]}" \
    --memory "${CLIENT_MEMORY_MB}m" \
    --memory-swap "${CLIENT_MEMORY_MB}m" \
    --ulimit nofile=65536:65536 \
    "$IMAGE" /opt/pabrik/api-bench \
      --port "$PORT" \
      --scenario "$SCENARIOS" \
      --requests "$REQUESTS" \
      --concurrency "$CONCURRENCY" \
      --warmup "$WARMUP" \
      --profile "$PROFILE" \
      --server-cpuset "$SERVER_CPUSET" \
      --client-cpuset "$CLIENT_CPUSET" \
      --memory-mb "$MEMORY_MB" \
      --min-scaling "$MIN_SCALING" \
      --max-p99-ms "$MAX_P99_MS" \
      --min-rps "$MIN_RPS" \
      --server-binary-sha256 "$digest" \
      "${STRICT_ARGS[@]}" \
      --json /tmp/api-bench.json \
      --markdown /tmp/api-bench.md
  rc=$?
  "$ENGINE" cp "$client:/tmp/api-bench.json" "$OUT_DIR/api-bench.json" >/dev/null 2>&1 || true
  "$ENGINE" cp "$client:/tmp/api-bench.md" "$OUT_DIR/api-bench.md" >/dev/null 2>&1 || true
  "$ENGINE" rm -f "$client" >/dev/null 2>&1 || true
  set -e

  [ -f "$OUT_DIR/api-bench.json" ] || die "the run produced no api-bench.json (exit $rc)"
  printf 'api-bench: artifacts in %s/api-bench.{json,md} and %s/server.log\n' "$OUT_DIR" "$OUT_DIR"
  return "$rc"
}

resolve_profile
cpuset_args "$SERVER_CPUSET" "$CLIENT_CPUSET"
strict_args "$STRICT"

action="${1:-run}"

case "$action" in
  selftest) selftest ;;
  spec) spec ;;
  image)
    check_engine
    check_binary
    build_loadgen
    build_image
    ;;
  run)
    spec
    check_engine
    check_binary
    check_cpus
    build_loadgen
    build_image
    run_bench
    ;;
  -h|--help|help) usage ;;
  *) usage; die "unknown action: $action" ;;
esac
