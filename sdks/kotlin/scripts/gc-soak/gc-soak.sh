#!/usr/bin/env bash
# WasmGC soak/stress test: drive intense allocation churn across thousands of Kotlin/Wasm agents and
# prove the collector runs (host RSS plateaus) with zero failed invokes (behavioral survival).
# Two tiers via MODE=smoke|soak. Requires branch-built golem/golem-cli (wasm_gc engine flag),
# mavenLocal-published SDK/KSP/gradle-plugin, and k6 on PATH (brew install k6).
#
# SERVER_MODE:
#   redis   (default) — Docker Redis + host multi-service stack with KVStoreRedis indexed storage
#             (same architecture as golem-agent-example docker-compose; avoids MultiSqlite EAGAIN).
#   builtin — monolithic `golem server run` (MultiSqlite; fine for small smoke, fails at ~thousands
#             of concurrent agents with SQLite "Resource temporarily unavailable").
#
# Usage: gc-soak.sh <workdir>
# Env: MODE SERVER_MODE AGENTS DURATION RATE VUS CHURN_OBJECTS RSS_SAMPLE_SEC RSS_PLATEAU_TOL
set -uo pipefail
WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../sdks/kotlin/scripts/gc-soak
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"                # repo root (gc-soak->scripts->kotlin->sdks->root)
GOLEM="${GOLEM_BIN:-$ROOT/target/debug/golem}"
GOLEM_CLI="${GOLEM_CLI_BIN:-$ROOT/target/debug/golem-cli}"
SDK_DIR="$(cd "$SCRIPT_DIR/../../sdk" && pwd)"               # .../sdks/kotlin/sdk
MODE="${MODE:-smoke}"
SERVER_MODE="${SERVER_MODE:-redis}"
fail() { echo "FAIL: $*"; exit 1; }
command -v k6 >/dev/null 2>&1 || fail "k6 not found on PATH (brew install k6)"

# Mode-derived defaults; any knob may be overridden explicitly.
if [ "$MODE" = "soak" ]; then
  # Defaults sized for a single host executor: many agents + large per-call churn
  # (WasmGC stress), not a synthetic 2k RPS that only produces client timeouts.
  AGENTS="${AGENTS:-2000}"; DURATION="${DURATION:-30m}"; RATE="${RATE:-20}"
  VUS="${VUS:-64}"; CHURN_OBJECTS="${CHURN_OBJECTS:-60000}"
elif [ "$MODE" = "smoke" ]; then
  AGENTS="${AGENTS:-50}"; DURATION="${DURATION:-60s}"; RATE="${RATE:-20}"
  VUS="${VUS:-32}"; CHURN_OBJECTS="${CHURN_OBJECTS:-20000}"
else
  fail "MODE must be smoke or soak (got '$MODE')"
fi
RSS_SAMPLE_SEC="${RSS_SAMPLE_SEC:-2}"
RSS_PLATEAU_TOL="${RSS_PLATEAU_TOL:-0.15}"
echo "== MODE=$MODE SERVER_MODE=$SERVER_MODE AGENTS=$AGENTS DURATION=$DURATION RATE=$RATE VUS=$VUS CHURN_OBJECTS=$CHURN_OBJECTS =="

SERVER_PID=""; SAMPLER_PID=""; STACK_PIDS_FILE=""
stop_server() {
  if [ -n "$STACK_PIDS_FILE" ] && [ -f "$STACK_PIDS_FILE" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done <"$STACK_PIDS_FILE"
    wait 2>/dev/null || true
    # leave redis container running only for this project cleanup
    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
      COMPOSE=(docker-compose)
      docker compose version >/dev/null 2>&1 && COMPOSE=(docker compose)
      "${COMPOSE[@]}" -f "$SCRIPT_DIR/docker/docker-compose.yaml" -p gcsoak down >/dev/null 2>&1 || true
    fi
  elif [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
stop_sampler() { [ -n "$SAMPLER_PID" ] && { kill "$SAMPLER_PID" 2>/dev/null || true; } || true; }
trap 'stop_sampler; stop_server' EXIT

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/app-parent" "$WORKDIR/server-data" "$WORKDIR/logs"

echo "== scaffold + fixture =="
(cd "$WORKDIR/app-parent" && "$GOLEM_CLI" new --template kotlin --component-name example:counter --yes app)
APP="$WORKDIR/app-parent/app"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"; mkdir -p "$APP/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
chmod +x "$APP/gradlew"
sed "s/CHURN_OBJECTS/$CHURN_OBJECTS/" "$SCRIPT_DIR/GcStressAgent.kt.fixture" \
  > "$(find "$APP" -name CounterAgent.kt | head -1)"

echo "== build =="
(cd "$APP" && "$GOLEM_CLI" build) || fail "build"

CUSTOM_PORT=""
RSS_TARGET_PID=""

if [ "$SERVER_MODE" = "redis" ]; then
  echo "== serve (Redis-backed multi-service stack) =="
  bash "$SCRIPT_DIR/start-redis-stack.sh" "$WORKDIR" || fail "redis stack start"
  STACK_PIDS_FILE="$WORKDIR/stack.pids"
  # shellcheck disable=SC1090
  set -a; source "$WORKDIR/stack.env"; set +a
  # golem-cli builtin local profile must hit the multi-service registry (not missing :9881)
  export GOLEM_BUILTIN_LOCAL_URL="${GOLEM_BUILTIN_LOCAL_URL:-http://localhost:${REGISTRY_HTTP:-8080}}"
  RSS_TARGET_PID="$EXECUTOR_PID"
  [ -n "$CUSTOM_PORT" ] || fail "no custom request port from stack"
elif [ "$SERVER_MODE" = "builtin" ]; then
  echo "== serve (builtin golem server run / MultiSqlite) =="
  rm -f "$WORKDIR/ports.json"
  "$GOLEM" server run --data-dir "$WORKDIR/server-data" --ports-file "$WORKDIR/ports.json" >"$WORKDIR/server.log" 2>&1 &
  SERVER_PID=$!
  RSS_TARGET_PID=$SERVER_PID
  for _ in $(seq 1 60); do [ -s "$WORKDIR/ports.json" ] && break; sleep 1; done
  CUSTOM_PORT="$(grep -o '"customRequestPort": *[0-9]*' "$WORKDIR/ports.json" | grep -o '[0-9]*')"
  [ -n "$CUSTOM_PORT" ] || fail "no custom request port"
else
  fail "SERVER_MODE must be redis or builtin (got '$SERVER_MODE')"
fi

echo "== deploy =="
(cd "$APP" && "$GOLEM_CLI" deploy --yes) || fail "deploy"

# Fail fast if registry never stored the wasm in the shared blob root.
if [ "$SERVER_MODE" = "redis" ]; then
  # shellcheck disable=SC1090
  set -a; source "$WORKDIR/stack.env"; set +a
  BLOB_ROOT="${BLOB_ROOT:-$WORKDIR/data/blob}"
  n_blob=$(find "$BLOB_ROOT/component_store" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  component_store files under $BLOB_ROOT: $n_blob"
  [ "${n_blob:-0}" -ge 1 ] || fail "deploy left component_store empty (blob/registry mismatch); see $WORKDIR/logs/registry-service.log"
fi

echo "== warm a few agents =="
for i in 0 1 2; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
    -X POST "http://localhost:$CUSTOM_PORT/gcstress/$i/churn/$CHURN_OBJECTS" \
    -H 'Host: app.localhost:9006' || echo 000)
  echo "  warm agent $i -> HTTP $code"
  [ "$code" = "200" ] || fail "warm agent $i returned HTTP $code (expected 200); component download likely broken"
done

echo "== start RSS sampler (pid=$RSS_TARGET_PID) =="
: > "$WORKDIR/rss.csv"; echo "epoch,rss_kb" >> "$WORKDIR/rss.csv"
(
  while :; do
    ps_args=(-p "$RSS_TARGET_PID")
    while read -r c; do
      [ -n "$c" ] && ps_args+=(-p "$c")
    done < <(pgrep -P "$RSS_TARGET_PID" 2>/dev/null || true)
    rss="$(ps -o rss= "${ps_args[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    echo "$(date +%s),$rss" >> "$WORKDIR/rss.csv"
    sleep "$RSS_SAMPLE_SEC"
  done
) &
SAMPLER_PID=$!

echo "== run k6 soak =="
BASE_URL="http://localhost:$CUSTOM_PORT" HOST_HEADER="app.localhost:9006" \
AGENTS="$AGENTS" RATE="$RATE" VUS="$VUS" DURATION="$DURATION" \
CHURN_OBJECTS="$CHURN_OBJECTS" WORKDIR="$WORKDIR" \
  k6 run "$SCRIPT_DIR/gc-soak.k6.js"
K6_RC=$?

stop_sampler

echo "== gate 1: behavioral survival (k6 exit code) =="
[ "$K6_RC" -eq 0 ] || fail "k6 reported failed requests / threshold breach (rc=$K6_RC); see $WORKDIR/k6-summary.json"

echo "== gate 2: host-memory plateau =="
"$SCRIPT_DIR/rss-plateau-check.sh" "$WORKDIR/rss.csv" "$RSS_PLATEAU_TOL" || fail "RSS did not plateau (possible leak / GC not reclaiming); see $WORKDIR/rss.csv"

echo "== secondary: guest stats =="
curl -s "http://localhost:$CUSTOM_PORT/gcstress/0/stats" -H 'Host: app.localhost:9006'; echo ""

echo "== GC SOAK PASS (MODE=$MODE SERVER_MODE=$SERVER_MODE): survival + RSS plateau. Artifacts in $WORKDIR =="
