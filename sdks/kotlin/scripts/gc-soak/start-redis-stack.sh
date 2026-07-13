#!/usr/bin/env bash
# Start a multi-service Golem stack for WasmGC soak, matching the storage model of
# https://github.com/JohnSColeman/golem-agent-example/blob/infra/infra/docker/docker-compose.yaml
#
#   - Postgres: registry DB
#   - Redis:    worker-executor key-value + indexed storage (KVStoreRedis), gateway sessions
#   - NO SQLite on registry or executor hot path (the prior soak panic was SQLite pool timeout)
#
# Golem services run as host debug binaries built from kotlin-sdk-native (WasmGC flags).
# Infra (redis + postgres) prefers Docker; redis-server is a fallback for Redis only.
#
# Writes $WORKDIR/stack.pids and $WORKDIR/stack.env (ports + worker-executor pid).
set -euo pipefail

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"
mkdir -p "$WORKDIR/data/blob" "$WORKDIR/data/shard" "$WORKDIR/logs"

fail() { echo "FAIL: $*"; exit 1; }

# Prefer Colima docker socket when present (macOS).
if [ -S "$HOME/.colima/default/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi

for bin in worker-executor golem-registry-service golem-worker-service golem-shard-manager golem-component-compilation-service; do
  [ -x "$ROOT/target/debug/$bin" ] || fail "missing $ROOT/target/debug/$bin — cargo build -p golem-worker-executor -p golem-registry-service -p golem-worker-service -p golem-shard-manager -p golem-component-compilation-service"
done

# Ports (aligned with local-run + builtin golem-cli profile on 9881 / custom 9006)
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
# Must match golem_client::LOCAL_WELL_KNOWN_TOKEN (golem-cli builtin local profile).
ADMIN_TOKEN="5c832d93-ff85-4a8f-9803-513950fdfdb1"

: >"$WORKDIR/stack.pids"
log_pid() { echo "$1" >>"$WORKDIR/stack.pids"; }

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
    "${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak up -d redis postgres

    # Wait until Redis is reachable from the HOST (docker exec can succeed before port publish is ready).
    for _ in $(seq 1 60); do
      if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG && break
      else
        # no redis-cli: TCP open is enough
        (echo >/dev/tcp/127.0.0.1/"$REDIS_PORT") >/dev/null 2>&1 && break
      fi
      sleep 1
    done
    if command -v redis-cli >/dev/null 2>&1; then
      redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG || fail "host redis :$REDIS_PORT not ready"
    fi
    echo "  redis ready on host :$REDIS_PORT"

    for _ in $(seq 1 60); do
      if command -v pg_isready >/dev/null 2>&1; then
        pg_isready -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break
      else
        pcid=$("${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak ps -q postgres 2>/dev/null || true)
        [ -n "$pcid" ] && docker exec "$pcid" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break
      fi
      sleep 1
    done
    if command -v pg_isready >/dev/null 2>&1; then
      pg_isready -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 \
        || fail "host postgres :$PG_PORT not ready"
    else
      pcid=$("${COMPOSE[@]}" -f "$DOCKER_DIR/docker-compose.yaml" -p gcsoak ps -q postgres 2>/dev/null || true)
      [ -n "$pcid" ] && docker exec "$pcid" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 \
        || fail "postgres not ready"
    fi
    echo "  postgres ready on host :$PG_PORT"
    return 0
  fi

  # Host redis only — no postgres without docker
  command -v redis-server >/dev/null 2>&1 || fail "docker unavailable and redis-server not found"
  echo "WARN: docker unavailable — host redis only; registry will fail without Postgres"
  echo "== redis (host redis-server) on :$REDIS_PORT =="
  redis-cli -p "$REDIS_PORT" ping >/dev/null 2>&1 && redis-cli -p "$REDIS_PORT" shutdown nosave >/dev/null 2>&1 || true
  redis-server --port "$REDIS_PORT" --save "" --appendonly no --stop-writes-on-bgsave-error no \
    --dir "$WORKDIR/data" >"$WORKDIR/logs/redis.log" 2>&1 &
  log_pid $!
  for _ in $(seq 1 30); do
    redis-cli -p "$REDIS_PORT" ping 2>/dev/null | grep -q PONG && return 0
    sleep 1
  done
  fail "redis not ready on :$REDIS_PORT"
}
start_infra

export RUST_BACKTRACE=1
export GOLEM__TRACING__STDOUT__ENABLED="${GOLEM__TRACING__STDOUT__ENABLED:-false}"
export GOLEM__TRACING__FILE__ENABLED=true
export GOLEM__TRACING__FILE_DIR="$WORKDIR/logs"

echo "== registry-service (Postgres) =="
(
  cd "$ROOT/golem-registry-service"
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  GOLEM__HTTP_PORT=$REGISTRY_HTTP \
  GOLEM__GRPC__PORT=$REGISTRY_GRPC \
  GOLEM__LOGIN__TYPE=Disabled \
  GOLEM__COMPILATION__TYPE=Enabled \
  GOLEM__COMPILATION__CONFIG__HOST=localhost \
  GOLEM__COMPILATION__CONFIG__PORT=$COMPILATION_GRPC \
  GOLEM__DB__TYPE=Postgres \
  GOLEM__DB__CONFIG__DATABASE=$PG_DB \
  GOLEM__DB__CONFIG__HOST=localhost \
  GOLEM__DB__CONFIG__PORT=$PG_PORT \
  GOLEM__DB__CONFIG__USERNAME=$PG_USER \
  GOLEM__DB__CONFIG__PASSWORD=$PG_PASS \
  GOLEM__DB__CONFIG__MAX_CONNECTIONS=20 \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$WORKDIR/data/blob" \
  GOLEM__CORS_ORIGIN_REGEX=".*" \
  GOLEM__INITIAL_ACCOUNTS__ROOT__TOKEN="$ADMIN_TOKEN" \
  "$ROOT/target/debug/golem-registry-service"
) >"$WORKDIR/logs/registry.log" 2>&1 &
log_pid $!

echo "== component-compilation-service =="
(
  cd "$ROOT/golem-component-compilation-service"
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  GOLEM__HTTP_PORT=$COMPILATION_HTTP \
  GOLEM__GRPC__PORT=$COMPILATION_GRPC \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$WORKDIR/data/blob" \
  GOLEM__REGISTRY_SERVICE__CONFIG__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__CONFIG__PORT=$REGISTRY_GRPC \
  "$ROOT/target/debug/golem-component-compilation-service"
) >"$WORKDIR/logs/compilation.log" 2>&1 &
log_pid $!

echo "== shard-manager =="
(
  cd "$ROOT/golem-shard-manager"
  # low-churn service; Redis persistence if we can, else local sqlite under workdir
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  GOLEM__HTTP_PORT=$SHARD_HTTP \
  GOLEM__GRPC__PORT=$SHARD_GRPC \
  GOLEM__PERSISTENCE__TYPE=Redis \
  GOLEM__PERSISTENCE__CONFIG__HOST=localhost \
  GOLEM__PERSISTENCE__CONFIG__PORT=$REDIS_PORT \
  GOLEM__REGISTRY_SERVICE__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__PORT=$REGISTRY_GRPC \
  "$ROOT/target/debug/golem-shard-manager"
) >"$WORKDIR/logs/shard-manager.log" 2>&1 &
log_pid $!

echo "== worker-executor (Redis KV + KVStoreRedis indexed — no SQLite) =="
# Pure Redis key-value (NOT NamespaceRouted/SQLite persistent — that caused the soak panic).
# Matches golem-agent-example docker-compose: KEY_VALUE_STORAGE=Redis, INDEXED_STORAGE=KVStoreRedis.
(
  cd "$ROOT/golem-worker-executor"
  RUST_LOG=info \
  GOLEM__HTTP_PORT=$EXECUTOR_HTTP \
  GOLEM__GRPC__PORT=$EXECUTOR_GRPC \
  GOLEM__PUBLIC_WORKER_API__HOST=localhost \
  GOLEM__PUBLIC_WORKER_API__PORT=$WORKER_GRPC \
  GOLEM__BLOB_STORAGE__TYPE=LocalFileSystem \
  GOLEM__BLOB_STORAGE__CONFIG__ROOT="$WORKDIR/data/blob" \
  GOLEM__REGISTRY_SERVICE__HOST=localhost \
  GOLEM__REGISTRY_SERVICE__PORT=$REGISTRY_GRPC \
  GOLEM__SHARD_MANAGER__HOST=localhost \
  GOLEM__SHARD_MANAGER__PORT=$SHARD_GRPC \
  GOLEM__SHARD_MANAGER__RETRIES__MAX_ATTEMPTS=10 \
  GOLEM__SHARD_MANAGER__RETRIES__MIN_DELAY=1s \
  GOLEM__KEY_VALUE_STORAGE__TYPE=Redis \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__HOST=localhost \
  GOLEM__KEY_VALUE_STORAGE__CONFIG__PORT=$REDIS_PORT \
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
  "$ROOT/target/debug/worker-executor"
) >"$WORKDIR/logs/worker-executor.log" 2>&1 &
EXECUTOR_PID=$!
log_pid $EXECUTOR_PID

echo "== worker-service (Redis gateway sessions) =="
(
  cd "$ROOT/golem-worker-service"
  RUST_LOG=info,h2=warn,hyper=warn,tower=warn \
  GOLEM__PORT=$WORKER_HTTP \
  GOLEM__CUSTOM_REQUEST_PORT=$CUSTOM_PORT \
  GOLEM__MCP_PORT=$MCP_PORT \
  GOLEM__GRPC__PORT=$WORKER_GRPC \
  GOLEM__GATEWAY_SESSION_STORAGE__TYPE=Redis \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__HOST=localhost \
  GOLEM__GATEWAY_SESSION_STORAGE__CONFIG__PORT=$REDIS_PORT \
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
  GOLEM__REGISTRY_SERVICE__PORT=$REGISTRY_GRPC \
  GOLEM__SHARD_MANAGER__HOST=localhost \
  GOLEM__SHARD_MANAGER__PORT=$SHARD_GRPC \
  GOLEM__CORS_ORIGIN_REGEX=".*" \
  "$ROOT/target/debug/golem-worker-service"
) >"$WORKDIR/logs/worker-service.log" 2>&1 &
log_pid $!

# Lightweight router so golem-cli builtin profile (localhost:9881) works
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
else
  echo "WARN: nginx not found — setting GOLEM_BUILTIN_LOCAL_URL to registry :$REGISTRY_HTTP"
  GOLEM_URL="http://localhost:$REGISTRY_HTTP"
  ROUTER_PORT=$REGISTRY_HTTP
fi

echo "== wait for registry =="
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$REGISTRY_HTTP/" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && break
  sleep 1
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$REGISTRY_HTTP/" 2>/dev/null || echo 000)
[ "$code" != "000" ] || {
  echo "registry log:"; tail -50 "$WORKDIR/logs/registry-service.log" 2>/dev/null || tail -50 "$WORKDIR/logs/registry.log"
  fail "registry not ready"
}

sleep 2
kill -0 "$EXECUTOR_PID" 2>/dev/null || {
  echo "executor log:"; cat "$WORKDIR/logs/worker-executor.log"
  tail -30 "$WORKDIR/logs/worker-executor."*.log 2>/dev/null || true
  fail "worker-executor exited"
}

for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$CUSTOM_PORT/" 2>/dev/null || echo 000)
  [ "$code" != "000" ] && break
  sleep 1
done

cat >"$WORKDIR/stack.env" <<EOF
CUSTOM_PORT=$CUSTOM_PORT
ROUTER_PORT=$ROUTER_PORT
REGISTRY_HTTP=$REGISTRY_HTTP
EXECUTOR_PID=$EXECUTOR_PID
REDIS_PORT=$REDIS_PORT
PG_PORT=$PG_PORT
ADMIN_TOKEN=$ADMIN_TOKEN
GOLEM_BUILTIN_LOCAL_URL=$GOLEM_URL
EOF

echo "== stack ready (Postgres registry + Redis executor KV/indexed): custom=:$CUSTOM_PORT golem_url=$GOLEM_URL executor_pid=$EXECUTOR_PID =="
