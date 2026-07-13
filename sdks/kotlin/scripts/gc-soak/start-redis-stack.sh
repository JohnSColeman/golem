#!/usr/bin/env bash
# Start a multi-service Golem stack for WasmGC soak.
# Topology/storage model match the proven agent-example docker-compose:
#   https://github.com/JohnSColeman/golem-agent-example/blob/infra/infra/docker/docker-compose.yaml
#
#   - Postgres: registry + shard-manager DB
#   - Redis:    executor key-value + indexed storage (KVStoreRedis), gateway sessions
#   - Shared host blob root for registry / compilation / executor
#   - NO SQLite on any hot path
#
# Golem services run as host debug binaries (WasmGC). Docker only for redis + postgres.
# Writes $WORKDIR/stack.pids and $WORKDIR/stack.env.
set -euo pipefail

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"
mkdir -p "$WORKDIR/data/blob" "$WORKDIR/logs"

fail() { echo "FAIL: $*"; exit 1; }

if [ -S "$HOME/.colima/default/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi

for bin in worker-executor golem-registry-service golem-worker-service golem-shard-manager golem-component-compilation-service; do
  [ -x "$ROOT/target/debug/$bin" ] || fail "missing $ROOT/target/debug/$bin"
done

REGISTRY_HTTP=8080
REGISTRY_GRPC=9090
COMPILATION_HTTP=8081
COMPILATION_GRPC=9091
SHARD_HTTP=8082
SHARD_GRPC=9092
EXECUTOR_HTTP=8083
EXECUTOR_GRPC=9093
WORKER_HTTP=8084
WORKER_GRPC=9094
CUSTOM_PORT=9006
MCP_PORT=9007
ROUTER_PORT=9881
REDIS_PORT=6380
PG_PORT=5432
PG_DB=golem_db
PG_USER=golem_user
PG_PASS=golem_password
ADMIN_TOKEN="5c832d93-ff85-4a8f-9803-513950fdfdb1"

: >"$WORKDIR/stack.pids"
log_pid() { echo "$1" >>"$WORKDIR/stack.pids"; }

# Start a binary with env; exec so the logged PID is the real process.
# Usage: start_svc name logfile cwd env=val... binary [args]
# cwd is the crate dir (config/*.toml is loaded relative to it).
start_svc() {
  local name="$1" logfile="$2" svc_cwd="$3"; shift 3
  (
    cd "$svc_cwd"
    export RUST_BACKTRACE=1
    export GOLEM__TRACING__STDOUT__ENABLED=false
    export GOLEM__TRACING__FILE__ENABLED=true
    export GOLEM__TRACING__FILE_DIR="$WORKDIR/logs"
    exec env "$@"
  ) >"$logfile" 2>&1 &
  local pid=$!
  log_pid "$pid"
  echo "  started $name pid=$pid cwd=$svc_cwd"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || {
    echo "--- $name log ---"; cat "$logfile"
    tail -20 "$WORKDIR/logs"/"$name"* 2>/dev/null || true
    fail "$name exited immediately"
  }
  eval "${name}_PID=$pid"
}

wait_tcp() {
  local host="$1" port="$2" label="$3" tries="${4:-60}"
  local i
  for i in $(seq 1 "$tries"); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      echo "  $label ready on $host:$port"
      return 0
    fi
    sleep 0.5
  done
  fail "$label not listening on $host:$port"
}

wait_http() {
  local url="$1" label="$2" tries="${3:-90}"
  local i code
  for i in $(seq 1 "$tries"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null || echo 000)
    if [ "$code" != "000" ]; then
      echo "  $label HTTP ready ($code) $url"
      return 0
    fi
    sleep 0.5
  done
  fail "$label not ready at $url"
}

COMPOSE=(docker-compose)
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
fi
HAS_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  HAS_DOCKER=1
fi

start_infra() {
  if [ "$HAS_DOCKER" -eq 1 ]; then
    echo "== infra (docker): redis :$REDIS_PORT + postgres :$PG_PORT =="
    export REDIS_HOST_PORT="$REDIS_PORT"
    export POSTGRES_HOST_PORT="$PG_PORT"
    # Always recreate volumes so Postgres component metadata cannot outlive a wiped
    # filesystem blob root (that mismatch causes ComponentDownloadFailed / empty component_store).
    "${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak down -v --remove-orphans >/dev/null 2>&1 || true
    "${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak up -d redis postgres

    for _ in $(seq 1 60); do
      redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG && break
      sleep 1
    done
    redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG \
      || fail "host redis :$REDIS_PORT not ready"
    echo "  redis ready on host :$REDIS_PORT"

    for _ in $(seq 1 60); do
      pcid=$("${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak ps -q postgres 2>/dev/null || true)
      if [ -n "$pcid" ] && docker exec "$pcid" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        echo "  postgres ready on host :$PG_PORT (fresh volume)"
        return 0
      fi
      sleep 1
    done
    fail "postgres not ready"
  fi

  fail "docker required for Postgres registry (compose). Start Colima and retry."
}
start_infra

# Shared blob root for registry + executor (component_store lives here).
# Created before services start so both open the same directory.
BLOB_ROOT="$WORKDIR/data/blob"
mkdir -p "$BLOB_ROOT"
chmod 755 "$BLOB_ROOT"
echo "  blob root: $BLOB_ROOT"

echo "== registry-service (Postgres + shared blob) =="
start_svc registry "$WORKDIR/logs/registry.log" "$ROOT/golem-registry-service" \
  GOLEM__HTTP_PORT="$REGISTRY_HTTP" \
  GOLEM__GRPC__PORT="$REGISTRY_GRPC" \
  GOLEM__LOGIN__TYPE=Disabled \
  GOLEM__COMPILATION__TYPE=Enabled \
  GOLEM__COMPILATION__CONFIG__HOST=localhost \
  GOLEM__COMPILATION__CONFIG__PORT="$COMPILATION_GRPC" \
  GOLEM__DB__TYPE=Postgres \
  GOLEM__DB__CONFIG__DATABASE="$PG_DB" \
  GOLEM__DB__CONFIG__HOST=localhost \
  GOLEM__DB__CONFIG__PORT="$PG_PORT" \
  GOLEM__DB__CONFIG__USERNAME="$PG_USER" \
  GOLEM__DB__CONFIG__PASSWORD="$PG_PASS" \
  GOLEM__DB__CONFIG__MAX_CONNECTIONS=20 \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$BLOB_ROOT" \
  GOLEM__CORS_ORIGIN_REGEX=".*" \
  GOLEM__INITIAL_ACCOUNTS__ROOT__TOKEN="$ADMIN_TOKEN" \
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  "$ROOT/target/debug/golem-registry-service"
wait_tcp 127.0.0.1 "$REGISTRY_GRPC" "registry grpc"
wait_http "http://127.0.0.1:$REGISTRY_HTTP/" "registry http"

echo "== component-compilation-service =="
start_svc compilation "$WORKDIR/logs/compilation.log" "$ROOT/golem-component-compilation-service" \
  GOLEM__HTTP_PORT="$COMPILATION_HTTP" \
  GOLEM__GRPC__PORT="$COMPILATION_GRPC" \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$BLOB_ROOT" \
  GOLEM__REGISTRY_SERVICE__TYPE=Static \
  GOLEM__REGISTRY_SERVICE__CONFIG__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__CONFIG__PORT="$REGISTRY_GRPC" \
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  "$ROOT/target/debug/golem-component-compilation-service"
wait_tcp 127.0.0.1 "$COMPILATION_GRPC" "compilation grpc"

echo "== shard-manager (Postgres — same topology as proven agent-example compose) =="
# Current shard-manager uses GOLEM__DB (Sqlite|Postgres); proven compose's Redis PERSISTENCE is gone.
# Fresh Postgres volume from start_infra means no stale executor pods.
start_svc shard_manager "$WORKDIR/logs/shard-manager.log" "$ROOT/golem-shard-manager" \
  GOLEM__HTTP_PORT="$SHARD_HTTP" \
  GOLEM__GRPC__PORT="$SHARD_GRPC" \
  GOLEM__DB__TYPE=Postgres \
  GOLEM__DB__CONFIG__DATABASE="$PG_DB" \
  GOLEM__DB__CONFIG__HOST=localhost \
  GOLEM__DB__CONFIG__PORT="$PG_PORT" \
  GOLEM__DB__CONFIG__USERNAME="$PG_USER" \
  GOLEM__DB__CONFIG__PASSWORD="$PG_PASS" \
  GOLEM__DB__CONFIG__MAX_CONNECTIONS=10 \
  GOLEM__DB__CONFIG__SCHEMA=golem_shard_manager \
  GOLEM__REGISTRY_SERVICE__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__PORT="$REGISTRY_GRPC" \
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  "$ROOT/target/debug/golem-shard-manager"
wait_tcp 127.0.0.1 "$SHARD_GRPC" "shard-manager grpc" 90

echo "== worker-executor (Redis KV + KVStoreRedis — no SQLite) =="
start_svc worker_executor "$WORKDIR/logs/worker-executor.log" "$ROOT/golem-worker-executor" \
  GOLEM__HTTP_PORT="$EXECUTOR_HTTP" \
  GOLEM__GRPC__PORT="$EXECUTOR_GRPC" \
  GOLEM__PUBLIC_WORKER_API__HOST=localhost \
  GOLEM__PUBLIC_WORKER_API__PORT="$WORKER_GRPC" \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$BLOB_ROOT" \
  GOLEM__REGISTRY_SERVICE__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__PORT="$REGISTRY_GRPC" \
  GOLEM__SHARD_MANAGER__HOST=127.0.0.1 \
  GOLEM__SHARD_MANAGER__PORT="$SHARD_GRPC" \
  GOLEM__SHARD_MANAGER__RETRIES__MAX_ATTEMPTS=20 \
  GOLEM__SHARD_MANAGER__RETRIES__MIN_DELAY=200ms \
  GOLEM__SHARD_MANAGER__RETRIES__MAX_DELAY=2s \
  GOLEM__KEY_VALUE_STORAGE__TYPE=Redis \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__HOST=127.0.0.1 \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__PORT="$REDIS_PORT" \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__DATABASE=0 \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__TRACING=false \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__TLS=false \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__KEY_PREFIX= \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__POOL_SIZE=32 \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__RETRIES__MAX_ATTEMPTS=5 \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__RETRIES__MIN_DELAY=100ms \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__RETRIES__MAX_DELAY=2s \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__RETRIES__MULTIPLIER=2 \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__RETRIES__MAX_JITTER_FACTOR=0.15 \
  GOLEM__INDEXED_STORAGE__TYPE=KVStoreRedis \
  GOLEM__SCHEDULER_STORAGE__TYPE=InMemory \
  GOLEM__COMPILED_COMPONENT_SERVICE__TYPE=Enabled \
  RUST_LOG=info \
  "$ROOT/target/debug/worker-executor"
EXECUTOR_PID=$worker_executor_PID
wait_tcp 127.0.0.1 "$EXECUTOR_GRPC" "worker-executor grpc" 60
kill -0 "$EXECUTOR_PID" 2>/dev/null || fail "worker-executor died after bind"

echo "== worker-service (Redis gateway sessions) =="
start_svc worker_service "$WORKDIR/logs/worker-service.log" "$ROOT/golem-worker-service" \
  GOLEM__PORT="$WORKER_HTTP" \
  GOLEM__CUSTOM_REQUEST_PORT="$CUSTOM_PORT" \
  GOLEM__MCP_PORT="$MCP_PORT" \
  GOLEM__GRPC__PORT="$WORKER_GRPC" \
  GOLEM__GATEWAY_SESSION_STORAGE__TYPE=Redis \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__HOST=127.0.0.1 \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__PORT="$REDIS_PORT" \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__DATABASE=0 \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__TRACING=false \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__TLS=false \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__KEY_PREFIX= \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__POOL_SIZE=16 \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__RETRIES__MAX_ATTEMPTS=5 \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__RETRIES__MIN_DELAY=100ms \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__RETRIES__MAX_DELAY=2s \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__RETRIES__MULTIPLIER=2 \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__RETRIES__MAX_JITTER_FACTOR=0.15 \
  GOLEM__REGISTRY_SERVICE__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__PORT="$REGISTRY_GRPC" \
  GOLEM__SHARD_MANAGER__HOST=127.0.0.1 \
  GOLEM__SHARD_MANAGER__PORT="$SHARD_GRPC" \
  GOLEM__CORS_ORIGIN_REGEX=".*" \
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  "$ROOT/target/debug/golem-worker-service"
wait_tcp 127.0.0.1 "$CUSTOM_PORT" "custom HTTP" 30
wait_tcp 127.0.0.1 "$WORKER_GRPC" "worker-service grpc" 30

NGINX_CONF="$WORKDIR/nginx.conf"
cat >"$NGINX_CONF" <<EOF
daemon off;
error_log $WORKDIR/logs/nginx-error.log info;
pid $WORKDIR/nginx.pid;
events {}
http {
  access_log $WORKDIR/logs/nginx-access.log;
  client_max_body_size 1g;
  upstream registry-service { server 127.0.0.1:$REGISTRY_HTTP fail_timeout=0 max_fails=0; }
  upstream worker-service { server 127.0.0.1:$WORKER_HTTP fail_timeout=0 max_fails=0; }
  server {
    listen $ROUTER_PORT;
    server_name localhost;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    location ~ /v1/components/[^/]+/workers(.*)$ { proxy_pass http://worker-service; }
    location /v1/agents { proxy_pass http://worker-service; }
    location / { proxy_pass http://registry-service; }
  }
}
EOF

if command -v nginx >/dev/null 2>&1; then
  echo "== nginx router :$ROUTER_PORT =="
  nginx -e "$WORKDIR/logs/nginx-error.log" -c "$NGINX_CONF" -p "$WORKDIR" >"$WORKDIR/logs/nginx.log" 2>&1 &
  log_pid $!
  GOLEM_URL="http://localhost:$ROUTER_PORT"
  wait_tcp 127.0.0.1 "$ROUTER_PORT" "nginx" 20
else
  GOLEM_URL="http://localhost:$REGISTRY_HTTP"
  ROUTER_PORT=$REGISTRY_HTTP
fi

# Final liveness
kill -0 "$EXECUTOR_PID" 2>/dev/null || {
  echo "executor log:"; tail -40 "$WORKDIR/logs/worker-executor.log"
  tail -40 "$WORKDIR/logs"/worker-executor.*.log 2>/dev/null || true
  fail "worker-executor not running at end of stack start"
}

cat >"$WORKDIR/stack.env" <<EOF
CUSTOM_PORT=$CUSTOM_PORT
ROUTER_PORT=$ROUTER_PORT
REGISTRY_HTTP=$REGISTRY_HTTP
EXECUTOR_PID=$EXECUTOR_PID
REDIS_PORT=$REDIS_PORT
PG_PORT=$PG_PORT
BLOB_ROOT=$BLOB_ROOT
ADMIN_TOKEN=$ADMIN_TOKEN
GOLEM_BUILTIN_LOCAL_URL=$GOLEM_URL
EOF

echo "== stack ready (Postgres registry + Redis executor + shared blob $BLOB_ROOT): custom=:$CUSTOM_PORT golem_url=$GOLEM_URL executor_pid=$EXECUTOR_PID =="
