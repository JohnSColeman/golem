#!/usr/bin/env bash
# Build Golem service Docker images from THIS repo (kotlin-sdk-native / WasmGC).
# Uses in-tree Dockerfiles under golem-*/docker/Dockerfile — never pulls published
# golemservices images (latest stable: v1.5.1; WasmGC requires this branch build).
#
# The Dockerfiles COPY prebuilt release binaries from:
#   target/<RUST_TARGET>/release/{golem-registry-service,golem-shard-manager,worker-executor,...}
#
# On macOS, that means a Linux cross-build first (PLATFORM_OVERRIDE).
#
# Usage (from anywhere):
#   sdks/kotlin/scripts/gc-soak/docker/build-images.sh
#
# Env:
#   GOLEM_LOCAL_IMAGE_TAG  image tag (default: wasmgc)
#   PLATFORM_OVERRIDE     linux/arm64 | linux/amd64 (default: auto from `uname -m` / docker)
#   SKIP_CARGO_BUILD=1    skip cargo release build (binaries already present)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
TAG="${GOLEM_LOCAL_IMAGE_TAG:-wasmgc}"
cd "$ROOT"

# Prefer Colima docker socket when present (macOS).
if [ -S "$HOME/.colima/default/docker.sock" ]; then
  export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi
command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "FAIL: docker daemon not reachable (colima start?)"; exit 1; }

# Map host/docker arch → cargo target + PLATFORM_OVERRIDE
ARCH="${PLATFORM_OVERRIDE:-}"
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH="linux/arm64" ;;
    x86_64|amd64)  ARCH="linux/amd64" ;;
    *) echo "FAIL: unknown arch $(uname -m); set PLATFORM_OVERRIDE=linux/arm64|linux/amd64"; exit 1 ;;
  esac
fi
case "$ARCH" in
  linux/arm64) RUST_TARGET="aarch64-unknown-linux-gnu" ;;
  linux/amd64) RUST_TARGET="x86_64-unknown-linux-gnu" ;;
  *) echo "FAIL: PLATFORM_OVERRIDE must be linux/arm64 or linux/amd64 (got $ARCH)"; exit 1 ;;
esac

echo "== platform=$ARCH rust_target=$RUST_TARGET tag=$TAG =="

BINS=(
  "golem-registry-service"
  "golem-shard-manager"
  "worker-executor"
  "golem-worker-service"
  "golem-component-compilation-service"
  "golem-debugging-service"
)

if [ "${SKIP_CARGO_BUILD:-0}" != "1" ]; then
  echo "== cargo release build for $RUST_TARGET (WasmGC host flags from this branch) =="
  # Match Makefile.toml docker packaging: PLATFORM_OVERRIDE drives the linux target dir.
  if [ "$(uname -s)" = "Darwin" ] || [ ! -f "/etc/os-release" ]; then
    # Cross-compile for Linux containers from macOS (or non-linux hosts).
    rustup target add "$RUST_TARGET" 2>/dev/null || true
    PLATFORM_OVERRIDE="$ARCH" cargo make build-release 2>/dev/null \
      || cargo build --release --target "$RUST_TARGET" \
           -p golem-registry-service \
           -p golem-shard-manager \
           -p golem-worker-executor \
           -p golem-worker-service \
           -p golem-component-compilation-service \
           -p golem-debugging-service
  else
    # Native linux host: release into target/release, then stage into target/$RUST_TARGET/release
    # so Dockerfiles' COPY paths resolve uniformly.
    cargo build --release \
      -p golem-registry-service \
      -p golem-shard-manager \
      -p golem-worker-executor \
      -p golem-worker-service \
      -p golem-component-compilation-service \
      -p golem-debugging-service
    mkdir -p "target/$RUST_TARGET/release"
    for b in "${BINS[@]}"; do
      cp -f "target/release/$b" "target/$RUST_TARGET/release/$b"
    done
  fi
fi

for b in "${BINS[@]}"; do
  path="target/$RUST_TARGET/release/$b"
  if [ ! -x "$path" ]; then
    # Fallback: native release path (linux host without staging)
    path="target/release/$b"
  fi
  [ -x "$path" ] || { echo "FAIL: missing binary $b (looked under target/$RUST_TARGET/release and target/release)"; exit 1; }
  echo "  ok $path"
done

# Ensure Dockerfiles find binaries at target/$RUST_TARGET/release even when built native-linux
if [ -d target/release ] && [ ! -d "target/$RUST_TARGET/release" ]; then
  mkdir -p "target/$RUST_TARGET/release"
  for b in "${BINS[@]}"; do
    [ -x "target/release/$b" ] && cp -f "target/release/$b" "target/$RUST_TARGET/release/$b"
  done
fi

echo "== docker build (in-tree Dockerfiles, context=$ROOT) =="
export GOLEM_LOCAL_IMAGE_TAG="$TAG"
export GOLEM_REPO_ROOT="$ROOT"

build_one() {
  local name="$1"
  local dockerfile="$2"
  echo "--- building $name:$TAG ---"
  docker build \
    --platform "$ARCH" \
    -f "$dockerfile" \
    -t "${name}:${TAG}" \
    "$ROOT"
}

build_one golem-registry-service              golem-registry-service/docker/Dockerfile
build_one golem-shard-manager                golem-shard-manager/docker/Dockerfile
build_one golem-worker-executor              golem-worker-executor/docker/Dockerfile
build_one golem-worker-service               golem-worker-service/docker/Dockerfile
build_one golem-component-compilation-service golem-component-compilation-service/docker/Dockerfile
build_one golem-debugging-service            golem-debugging-service/docker/Dockerfile

echo "== built local images (tag=$TAG) =="
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' | grep -E "REPOSITORY|golem-.*${TAG}|golem-.*wasmgc" || docker images | head -20

echo ""
echo "Next:"
echo "  cd $SCRIPT_DIR"
echo "  GOLEM_LOCAL_IMAGE_TAG=$TAG GOLEM_REPO_ROOT=$ROOT docker compose --profile full up -d"
echo "  # or: MODE=soak SERVER_MODE=docker .../gc-soak.sh <workdir>"
