#!/usr/bin/env bash
# GC workload × concurrency factorial matrix + OLS regression.
#
# Matrix design (defaults for short runs):
#   Factor A — churn (per-call WasmGC allocations):  1000, 10000, 40000
#   Factor B — concurrency (k6 VUs = arrival rate):  1, 8, 32
#   Full factorial: 3 × 3 = 9 cells
#   Model: Y ~ 1 + z(churn) + z(vus) + z(churn)×z(vus)
#
# Long soak regression (e.g. 4h per cell → ~36h for 9 cells):
#   DURATION=4h REQ_TIMEOUT=120s SETTLE_SEC=30 RSS=1 \
#     ./gc-regression.sh /tmp/gc-regression-4h
#
# Resume after interrupt (keeps stack if still up, skips finished cells):
#   RESUME=1 SKIP_DEPLOY=1 ./gc-regression.sh /tmp/gc-regression-4h
#   # or RESUME=1 alone to rebuild stack but skip cells that already have k6-summary.json
#
# Usage:
#   ./gc-regression.sh <workdir>
#
# Env:
#   CHURNS VUS_LIST DURATION AGENTS REQ_TIMEOUT SETTLE_SEC BUILD_CHURN
#   RSS=1              sample executor RSS during each cell → cell-*/rss.csv
#   RSS_SAMPLE_SEC=10
#   RESUME=1           skip cells that already have k6-summary.json; append CSV carefully
#   SKIP_DEPLOY=1      reuse existing deploy/stack.env (implies app already built)
#   COPY_REPORT_TO     durable markdown path (default: suite REGRESSION-REPORT.md)
#   PROGRESSIVE=1      re-run OLS after every cell (default on for DURATION ≥ 30m)
set -euo pipefail

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
GOLEM_CLI="${GOLEM_CLI_BIN:-$ROOT/target/debug/golem-cli}"
SDK_DIR="$(cd "$SCRIPT_DIR/../../sdk" && pwd)"

fail() { echo "FAIL: $*"; exit 1; }
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
command -v k6 >/dev/null 2>&1 || fail "k6 not found (brew install k6)"
command -v python3 >/dev/null 2>&1 || fail "python3 required for regression analysis"
[ -x "$GOLEM_CLI" ] || fail "missing $GOLEM_CLI"

# --- matrix design defaults ---
CHURNS="${CHURNS:-1000 10000 40000}"
VUS_LIST="${VUS_LIST:-1 8 32}"
DURATION="${DURATION:-60s}"
AGENTS="${AGENTS:-32}"
REQ_TIMEOUT="${REQ_TIMEOUT:-120s}"
SETTLE_SEC="${SETTLE_SEC:-5}"
BUILD_CHURN="${BUILD_CHURN:-10000}"
RSS="${RSS:-0}"
RSS_SAMPLE_SEC="${RSS_SAMPLE_SEC:-10}"
RESUME="${RESUME:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
COPY_REPORT_TO="${COPY_REPORT_TO:-$SCRIPT_DIR/REGRESSION-REPORT.md}"

duration_to_seconds() {
  local d="$1"
  case "$d" in
    *ms) echo 1 ;;
    *s) echo "${d%s}" ;;
    *m) echo $(( ${d%m} * 60 )) ;;
    *h) echo $(( ${d%h} * 3600 )) ;;
    *) echo "$d" ;;
  esac
}
DURATION_S="$(duration_to_seconds "$DURATION")"

# Progressive OLS default: on for long cells
if [ -z "${PROGRESSIVE+x}" ] || [ -z "${PROGRESSIVE:-}" ]; then
  if [ "$DURATION_S" -ge 1800 ]; then PROGRESSIVE=1; else PROGRESSIVE=0; fi
fi

mkdir -p "$WORKDIR"
CELLS_CSV="$WORKDIR/cells.csv"
CSV_HEADER="cell_id,churn,vus,rate,agents,duration_s,http_reqs,fail_rate,check_pass_rate,latency_avg_ms,latency_p50_ms,latency_p90_ms,latency_p95_ms,latency_max_ms,dropped_iterations,completed_rate,rss_min_kb,rss_max_kb,rss_mean_kb,rss_end_kb,started_utc,ended_utc"

if [ "$RESUME" != "1" ] || [ ! -f "$CELLS_CSV" ]; then
  echo "$CSV_HEADER" >"$CELLS_CSV"
fi

STACK_PIDS_FILE=""
stop_server() {
  log "stopping stack (trap)"
  if [ -n "$STACK_PIDS_FILE" ] && [ -f "$STACK_PIDS_FILE" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done <"$STACK_PIDS_FILE"
    wait 2>/dev/null || true
    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
      COMPOSE=(docker-compose)
      docker compose version >/dev/null 2>&1 && COMPOSE=(docker compose)
      "${COMPOSE[@]}" -f "$SCRIPT_DIR/docker/docker-compose.yaml" -p gcsoak down >/dev/null 2>&1 || true
    fi
  fi
}
trap 'stop_server' EXIT

n_churn=0; for _ in $CHURNS; do n_churn=$((n_churn + 1)); done
n_vus=0; for _ in $VUS_LIST; do n_vus=$((n_vus + 1)); done
n_cells=$((n_churn * n_vus))
total_est_h=$(python3 -c "print(round($n_cells * $DURATION_S / 3600.0, 2))")

cat >"$WORKDIR/design.json" <<EOF
{
  "design": "full_factorial",
  "factors": {
    "churn": {"levels": [$(echo "$CHURNS" | sed 's/ /,/g')], "unit": "allocations_per_invoke", "role": "GC_workload"},
    "vus": {"levels": [$(echo "$VUS_LIST" | sed 's/ /,/g')], "unit": "concurrent_clients", "role": "concurrency", "note": "RATE set equal to VUs per cell"}
  },
  "cells": $n_cells,
  "duration_per_cell": "$DURATION",
  "duration_s": $DURATION_S,
  "estimated_wall_hours": $total_est_h,
  "agents": $AGENTS,
  "req_timeout": "$REQ_TIMEOUT",
  "rss_sampling": $([ "$RSS" = "1" ] && echo true || echo false),
  "outcomes": ["fail_rate", "latency_p95_ms", "latency_avg_ms", "rss_mean_kb"],
  "model": "Y ~ 1 + z(churn) + z(vus) + z(churn)*z(vus)",
  "stack": "SERVER_MODE=redis (Postgres registry + Redis KV/KVStoreRedis + shared blob)",
  "resume": $([ "$RESUME" = "1" ] && echo true || echo false)
}
EOF

log "== GC regression matrix =="
log "  design: full factorial  churn=[$CHURNS]  ×  vus=[$VUS_LIST]  →  $n_cells cells"
log "  DURATION=$DURATION (${DURATION_S}s each)  est. wall time ≈ ${total_est_h}h (+ build/deploy/settle)"
log "  AGENTS=$AGENTS REQ_TIMEOUT=$REQ_TIMEOUT SETTLE=${SETTLE_SEC}s RSS=$RSS RESUME=$RESUME"
log "  workdir=$WORKDIR"

# --- deploy ---
if [ "$SKIP_DEPLOY" = "1" ]; then
  [ -f "$WORKDIR/stack.env" ] || fail "SKIP_DEPLOY=1 but $WORKDIR/stack.env missing"
  # shellcheck disable=SC1090
  set -a; source "$WORKDIR/stack.env"; set +a
  [ -n "${CUSTOM_PORT:-}" ] || fail "no CUSTOM_PORT in stack.env"
  STACK_PIDS_FILE="$WORKDIR/stack.pids"
  # ensure stack still alive
  if [ -n "${EXECUTOR_PID:-}" ] && ! kill -0 "$EXECUTOR_PID" 2>/dev/null; then
    fail "EXECUTOR_PID=$EXECUTOR_PID not running; start without SKIP_DEPLOY or restart stack"
  fi
  log "reusing deploy (CUSTOM_PORT=$CUSTOM_PORT executor=$EXECUTOR_PID)"
else
  if [ "$RESUME" != "1" ]; then
    # Fresh run: wipe app/logs but keep any prior cell-* if RESUME was intended — not RESUME so wipe all
    rm -rf "$WORKDIR/app-parent" "$WORKDIR/data" "$WORKDIR/logs" "$WORKDIR/server-data"
  fi
  mkdir -p "$WORKDIR/app-parent" "$WORKDIR/logs" "$WORKDIR/server-data"

  if [ ! -d "$WORKDIR/app-parent/app" ]; then
    log "== scaffold + fixture (DEFAULT_CHURN=$BUILD_CHURN) =="
    (cd "$WORKDIR/app-parent" && "$GOLEM_CLI" new --template kotlin --component-name example:counter --yes app)
    APP="$WORKDIR/app-parent/app"
    cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"; mkdir -p "$APP/gradle/wrapper"
    cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
    chmod +x "$APP/gradlew"
    sed "s/CHURN_OBJECTS/$BUILD_CHURN/g" "$SCRIPT_DIR/GcStressAgent.kt.fixture" \
      > "$(find "$APP" -name CounterAgent.kt | head -1)"

    log "== build =="
    (cd "$APP" && "$GOLEM_CLI" build) || fail "build"
  else
    APP="$WORKDIR/app-parent/app"
    log "reusing existing app at $APP"
  fi

  log "== serve (redis stack) =="
  bash "$SCRIPT_DIR/start-redis-stack.sh" "$WORKDIR" || fail "stack start"
  STACK_PIDS_FILE="$WORKDIR/stack.pids"
  # shellcheck disable=SC1090
  set -a; source "$WORKDIR/stack.env"; set +a
  export GOLEM_BUILTIN_LOCAL_URL="${GOLEM_BUILTIN_LOCAL_URL:-http://localhost:${REGISTRY_HTTP:-8080}}"
  [ -n "${CUSTOM_PORT:-}" ] || fail "no CUSTOM_PORT"

  log "== deploy =="
  (cd "$APP" && "$GOLEM_CLI" deploy --yes) || fail "deploy"
  BLOB_ROOT="${BLOB_ROOT:-$WORKDIR/data/blob}"
  n_blob=$(find "$BLOB_ROOT/component_store" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "${n_blob:-0}" -ge 1 ] || fail "empty component_store after deploy (got $n_blob)"

  log "== warm (path /churn/{n} for each matrix churn level) =="
  for churn in $CHURNS; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 180 \
      -X POST "http://localhost:$CUSTOM_PORT/gcstress/0/churn/$churn" \
      -H 'Host: app.localhost:9006' || echo 000)
    log "  warm churn=$churn -> HTTP $code"
    [ "$code" = "200" ] || fail "warm churn=$churn -> HTTP $code (expected 200)"
  done
fi

EXECUTOR_PID="${EXECUTOR_PID:-}"

rss_stats() {
  local csv="$1"
  python3 - "$csv" <<'PY'
import csv, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("0,0,0,0"); raise SystemExit
rows = list(csv.DictReader(p.open()))
if not rows:
    print("0,0,0,0"); raise SystemExit
vals = [int(r["rss_kb"]) for r in rows if r.get("rss_kb")]
if not vals:
    print("0,0,0,0"); raise SystemExit
print(f"{min(vals)},{max(vals)},{sum(vals)/len(vals):.0f},{vals[-1]}")
PY
}

extract_cell() {
  local summary="$1" cell_id="$2" churn="$3" vus="$4" rate="$5" rss_csv="$6" started="$7" ended="$8"
  python3 - "$summary" "$cell_id" "$churn" "$vus" "$rate" "$AGENTS" "$DURATION_S" "$rss_csv" "$started" "$ended" <<'PY'
import json, sys, csv
from pathlib import Path
path, cell_id, churn, vus, rate, agents, dur_s, rss_csv, started, ended = sys.argv[1:11]
d = json.load(open(path))
m = d.get("metrics", {})

def vals(name):
    x = m.get(name) or {}
    return x.get("values", x) or {}

hr = vals("http_reqs")
hf = vals("http_req_failed")
ck = vals("checks")
hd = vals("http_req_duration")
di = vals("dropped_iterations")
it = vals("iterations")

http_reqs = float(hr.get("count") or 0)
fail_rate = float(hf.get("rate") or 0)
check_pass = float(ck.get("rate") or 0)
avg = float(hd.get("avg") or 0)
p50 = float(hd.get("med") or hd.get("p(50)") or 0)
p90 = float(hd.get("p(90)") or 0)
p95 = float(hd.get("p(95)") or 0)
mx = float(hd.get("max") or 0)
dropped = float(di.get("count") or 0)
completed_rate = float(it.get("rate") or hr.get("rate") or 0)

rss_min = rss_max = rss_mean = rss_end = 0
p = Path(rss_csv)
if p.is_file():
    rows = list(csv.DictReader(p.open()))
    vals_r = [int(r["rss_kb"]) for r in rows if r.get("rss_kb")]
    if vals_r:
        rss_min, rss_max = min(vals_r), max(vals_r)
        rss_mean = sum(vals_r) / len(vals_r)
        rss_end = vals_r[-1]

print(
    f"{cell_id},{churn},{vus},{rate},{agents},{dur_s},"
    f"{http_reqs:.0f},{fail_rate:.8f},{check_pass:.8f},"
    f"{avg:.4f},{p50:.4f},{p90:.4f},{p95:.4f},{mx:.4f},"
    f"{dropped:.0f},{completed_rate:.6f},"
    f"{rss_min:.0f},{rss_max:.0f},{rss_mean:.0f},{rss_end:.0f},"
    f"{started},{ended}"
)
PY
}

write_report() {
  local tag="${1:-}"
  python3 "$SCRIPT_DIR/gc-regression-analyze.py" "$CELLS_CSV" \
    --report "$WORKDIR/regression-report.md" \
    --design "$WORKDIR/design.json" >/dev/null 2>&1 || true
  {
    echo "# GC workload regression — live matrix results${tag:+ ($tag)}"
    echo ""
    echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "Workdir: \`$WORKDIR\`"
    echo ""
    cat "$WORKDIR/regression-report.md" 2>/dev/null || true
  } >"$WORKDIR/REGRESSION-REPORT.md"
  if [ -n "$COPY_REPORT_TO" ]; then
    cp "$WORKDIR/REGRESSION-REPORT.md" "$COPY_REPORT_TO" 2>/dev/null || true
  fi
}

# Rebuild CSV from completed cells when resuming (avoid duplicate rows)
if [ "$RESUME" = "1" ]; then
  echo "$CSV_HEADER" >"$CELLS_CSV"
  log "RESUME=1: rebuilding cells.csv from finished cell dirs"
fi

cell_i=0
failed_cells=0
skipped_cells=0
for churn in $CHURNS; do
  for vus in $VUS_LIST; do
    cell_i=$((cell_i + 1))
    cell_id=$(printf "c%02d" "$cell_i")
    rate="$vus"
    cell_dir="$WORKDIR/cell-${cell_id}-churn${churn}-vus${vus}"
    mkdir -p "$cell_dir"

    # Resume: already have summary → extract only
    if [ -f "$cell_dir/k6-summary.json" ]; then
      log "== cell $cell_i/$n_cells id=$cell_id churn=$churn vus=$vus — SKIP (already complete)"
      started=$(cat "$cell_dir/started_utc" 2>/dev/null || echo "")
      ended=$(cat "$cell_dir/ended_utc" 2>/dev/null || echo "")
      line=$(extract_cell "$cell_dir/k6-summary.json" "$cell_id" "$churn" "$vus" "$rate" \
        "$cell_dir/rss.csv" "$started" "$ended")
      echo "$line" >>"$CELLS_CSV"
      skipped_cells=$((skipped_cells + 1))
      continue
    fi

    log "== cell $cell_i/$n_cells  id=$cell_id  churn=$churn  vus=$vus  rate=$rate  duration=$DURATION =="
    log "  remaining est. hours: $(python3 -c "print(round(($n_cells - $cell_i + 1) * $DURATION_S / 3600.0, 2))")"

    if [ "$SETTLE_SEC" -gt 0 ]; then
      sleep "$SETTLE_SEC"
    fi

    started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$started_utc" >"$cell_dir/started_utc"

    # Optional RSS sampler on executor
    sampler_pid=""
    if [ "$RSS" = "1" ] && [ -n "$EXECUTOR_PID" ]; then
      : >"$cell_dir/rss.csv"
      echo "epoch,rss_kb" >>"$cell_dir/rss.csv"
      (
        while :; do
          ps_args=(-p "$EXECUTOR_PID")
          while read -r c; do
            [ -n "$c" ] && ps_args+=(-p "$c")
          done < <(pgrep -P "$EXECUTOR_PID" 2>/dev/null || true)
          rss="$(ps -o rss= "${ps_args[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
          echo "$(date +%s),$rss" >>"$cell_dir/rss.csv"
          sleep "$RSS_SAMPLE_SEC"
        done
      ) &
      sampler_pid=$!
    fi

    set +e
    BASE_URL="http://localhost:$CUSTOM_PORT" HOST_HEADER="app.localhost:9006" \
    AGENTS="$AGENTS" RATE="$rate" VUS="$vus" DURATION="$DURATION" \
    CHURN_OBJECTS="$churn" ENFORCE_THRESHOLDS=0 REQ_TIMEOUT="$REQ_TIMEOUT" \
    WORKDIR="$cell_dir" \
      k6 run --quiet "$SCRIPT_DIR/gc-soak.k6.js" >"$cell_dir/k6.stdout" 2>&1
    k6_rc=$?
    set -e

    if [ -n "$sampler_pid" ]; then
      kill "$sampler_pid" 2>/dev/null || true
      wait "$sampler_pid" 2>/dev/null || true
    fi

    ended_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$ended_utc" >"$cell_dir/ended_utc"
    log "  k6 exit=$k6_rc  started=$started_utc ended=$ended_utc"

    # Liveness check
    if [ -n "$EXECUTOR_PID" ] && ! kill -0 "$EXECUTOR_PID" 2>/dev/null; then
      fail "worker-executor died during cell $cell_id — aborting matrix"
    fi

    if [ ! -f "$cell_dir/k6-summary.json" ]; then
      log "  WARN: no k6-summary.json"
      failed_cells=$((failed_cells + 1))
      echo "${cell_id},${churn},${vus},${rate},${AGENTS},${DURATION_S},0,1.0,0.0,0,0,0,0,0,0,0,0,0,0,0,${started_utc},${ended_utc}" >>"$CELLS_CSV"
      continue
    fi

    line=$(extract_cell "$cell_dir/k6-summary.json" "$cell_id" "$churn" "$vus" "$rate" \
      "$cell_dir/rss.csv" "$started_utc" "$ended_utc")
    echo "$line" >>"$CELLS_CSV"
    log "  metrics: $line"
    echo "$line" >"$cell_dir/metrics.csv.line"

    if [ "$PROGRESSIVE" = "1" ]; then
      write_report "progressive after $cell_id"
      log "  progressive report updated"
    fi
  done
done

log "== OLS regression (failed=$failed_cells skipped_resume=$skipped_cells) =="
write_report "final"
# also print report to stdout for logs
cat "$WORKDIR/REGRESSION-REPORT.md" || true

log "== GC regression complete =="
log "  design: $WORKDIR/design.json"
log "  cells:  $CELLS_CSV"
log "  report: $WORKDIR/REGRESSION-REPORT.md"
[ -n "$COPY_REPORT_TO" ] && log "  durable: $COPY_REPORT_TO"
[ "$failed_cells" -eq 0 ] || log "  WARN: $failed_cells cell(s) missing k6-summary"
