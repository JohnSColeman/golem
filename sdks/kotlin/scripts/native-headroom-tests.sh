#!/usr/bin/env bash
# Arena headroom check: scaffold -> set `wasmComponent { arenaHeadroomKiB }` -> build -> deploy -> probe, on a second small app so the
# contract suite keeps covering the default headroom. Proves that the build setting reaches the SDK (the arena starts at the headroom),
# that an agent built with it is as small as the setting says, and that a print close to the limit works and leaves the agent usable.
# A print OVER the headroom fails the agent by design; that case is covered by MemoryTest, not here (a probe cannot expect a trap).
#
# Usage: native-headroom-tests.sh <workdir>
# Requires: SDK/KSP/gradle-plugin published to mavenLocal; golem/golem-cli built from this branch.
# HEADROOM_KIB (default 256) is the setting to test; HEADROOM_APPLY=0 builds WITHOUT the setting while still expecting it, to show the
# probes catch a setting that did not take effect. GOLEM_BIN/GOLEM_CLI_BIN override the built binary paths.
set -uo pipefail

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GOLEM="${GOLEM_BIN:-$ROOT/target/debug/golem}"
GOLEM_CLI="${GOLEM_CLI_BIN:-$ROOT/target/debug/golem-cli}"
FIXTURE="$SCRIPT_DIR/contract-tests/HeadroomProbeAgent.kt"
SDK_DIR="$SCRIPT_DIR/../sdk"
HEADROOM_KIB="${HEADROOM_KIB:-256}"
HEADROOM_APPLY="${HEADROOM_APPLY:-1}"
PAGE_KIB=64
PRINT_KIB=$((HEADROOM_KIB * 3 / 4))
# An agent of this component is about the headroom plus a few pages (the first use of the stdlib allocator takes two); the default
# headroom of 1024 KiB gives more than 1,056 KiB, so a bound well under that shows the setting took effect.
MAX_LINEAR_KIB=$((HEADROOM_KIB + 5 * PAGE_KIB))

PASS=0; FAIL=0
record() { # record <label> <PASS|FAIL> <detail>
  printf '  %-4s %-46s %s\n' "$2" "$1" "$3"
  if [ "$2" = PASS ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}
invoke() { (cd "$APP" && "$GOLEM_CLI" agent invoke "HeadroomProbeAgent(\"$1\")" "${@:2}" 2>&1); }

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/app-parent" "$WORKDIR/server-data"
echo "== scaffold (headroom ${HEADROOM_KIB} KiB, applied: ${HEADROOM_APPLY}) =="
(cd "$WORKDIR/app-parent" && "$GOLEM_CLI" new --template kotlin --component-name example:counter --yes app) || { echo "SCAFFOLD FAILED"; exit 2; }
APP="$WORKDIR/app-parent/app"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"
mkdir -p "$APP/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
chmod +x "$APP/gradlew"
cp "$FIXTURE" "$(find "$APP" -name CounterAgent.kt | head -1)"

python3 - "$APP" "$HEADROOM_KIB" "$HEADROOM_APPLY" <<'PY'
import sys
app, kib, apply = sys.argv[1], sys.argv[2], sys.argv[3]
build = app + "/build.gradle.kts"
text = open(build, encoding="utf-8").read()
if apply == "1":
    marker = 'moduleName.set("example_counter")\n'
    assert marker in text, "the scaffolded build.gradle.kts has no moduleName line to follow"
    text = text.replace(marker, marker + "    arenaHeadroomKiB.set(" + kib + ")\n", 1)
    open(build, "w", encoding="utf-8").write(text)
manifest = app + "/golem.yaml"
text = open(manifest, encoding="utf-8").read()
assert "        CounterAgent: {}\n" in text, "the scaffolded manifest does not list CounterAgent"
open(manifest, "w", encoding="utf-8").write(text.replace("        CounterAgent: {}\n", "        HeadroomProbeAgent: {}\n", 1))
PY

echo "== build =="
(cd "$APP" && "$GOLEM_CLI" build) || { echo "BUILD FAILED"; exit 2; }

echo "== server =="
"$GOLEM" server run --data-dir "$WORKDIR/server-data" --ports-file "$WORKDIR/ports.json" >"$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
waited=0
while [ ! -s "$WORKDIR/ports.json" ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "golem server exited during startup (see $WORKDIR/server.log)"; exit 2; }
  [ "$waited" -lt "${SERVER_WAIT_SECONDS:-600}" ] || { echo "golem server not ready after ${SERVER_WAIT_SECONDS:-600}s (see $WORKDIR/server.log)"; exit 2; }
  waited=$((waited + 1)); sleep 1
done
echo "   server ready after ${waited}s"

echo "== deploy =="
(cd "$APP" && "$GOLEM_CLI" deploy --yes) || { echo "DEPLOY FAILED"; exit 2; }

echo "== probes (expecting a ${HEADROOM_KIB} KiB headroom) =="
LOW=$((HEADROOM_KIB * 1024)); HIGH=$((LOW + PAGE_KIB * 1024))

out="$(invoke start arenaStart)"
at="$(echo "$out" | grep -o '"OK arena at [0-9]*' | grep -o '[0-9]*$' | tail -1)"
if [ -n "$at" ] && [ "$at" -ge "$LOW" ] && [ "$at" -lt "$HIGH" ]; then record "arena starts at the headroom" PASS "$at in [$LOW, $HIGH)"
else record "arena starts at the headroom" FAIL "got '${at:-none}', wanted [$LOW, $HIGH): $(echo "$out" | tail -1)"; fi

out="$(invoke printer printKiB "$PRINT_KIB")"
if echo "$out" | grep -q "\"OK printed $PRINT_KIB KiB"; then record "a ${PRINT_KIB} KiB println succeeds" PASS "within the ${HEADROOM_KIB} KiB headroom"
else record "a ${PRINT_KIB} KiB println succeeds" FAIL "$(echo "$out" | tail -1)"; fi

out="$(invoke printer arenaStart)"
if echo "$out" | grep -q '"OK arena at'; then record "the printing agent is still usable" PASS "the canary is intact"
else record "the printing agent is still usable" FAIL "$(echo "$out" | tail -1)"; fi

size="$(cd "$APP" && "$GOLEM_CLI" agent get 'HeadroomProbeAgent("start")' 2>&1 | grep -i 'linear memory size' | sed -E 's/.*: *([0-9.]+) *(KiB|MiB).*/\1 \2/')"
kib="$(echo "$size" | awk '{ if ($2 == "MiB") printf "%d", $1 * 1024; else printf "%d", $1 }')"
if [ -n "$kib" ] && [ "$kib" -le "$MAX_LINEAR_KIB" ]; then record "an agent is as small as the setting says" PASS "linear memory $size (limit ${MAX_LINEAR_KIB} KiB)"
else record "an agent is as small as the setting says" FAIL "linear memory '${size:-unknown}', wanted at most ${MAX_LINEAR_KIB} KiB"; fi

echo "== summary =="
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
