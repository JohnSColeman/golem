#!/usr/bin/env bash
# Builds the typed tool definition fixtures against the working-tree SDK, KSP processor and Gradle plugin:
#   library/       declares @ToolDefinition interfaces and is published to mavenLocal
#   component/     uses them from another module: a transparent middleware, an adapter, a typed client call
#   single-module/ declares the interface and its middleware in one module
# Exits non-zero on any failure. Requires java 17+, wasm-tools on PATH, network on first run (WASI adapter).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOTLIN="$(cd "$HERE/../.." && pwd)"
V="-PgolemSdkVersion=0.0.0-SNAPSHOT"

for module in sdk ksp gradle-plugin; do
  echo "== publish $module =="
  (cd "$KOTLIN/$module" && ./gradlew --console=plain publishToMavenLocal $V)
done

echo "== publish library =="
(cd "$HERE/library" && ./gradlew --console=plain publishToMavenLocal)

for project in component single-module; do
  echo "== build $project =="
  (cd "$HERE/$project" && ./gradlew --console=plain nativeComponent)
  wasm="$(find "$HERE/$project/build/golem" -name '*.wasm' | head -1)"
  [ -n "$wasm" ] || { echo "no component produced for $project" >&2; exit 1; }
  wasm-tools validate --features all "$wasm"
  wasm-tools component wit "$wasm" | grep -q 'golem:tool/tool-middleware-guest' \
    || { echo "$project does not export golem:tool/tool-middleware-guest" >&2; exit 1; }
  echo "$project: OK ($wasm)"
done
