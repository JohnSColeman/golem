#!/usr/bin/env bash
# Host-level snapshot round-trip: prove the worker-executor calls guest save-snapshot (old
# revision) + load-snapshot (new revision) during a manual update, carrying typed agent state
# across a revision bump AND a server restart. Mirrors hot_update.rs:agent_can_be_invoked_after_
# manual_snapshot_update_and_restart. Requires the Snapshotted<S> CounterAgent and a toolchain
# published to mavenLocal. GOLEM_BIN/GOLEM_CLI_BIN override the built binaries.
set -uo pipefail

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLEM="${GOLEM_BIN:-$(cd "$SCRIPT_DIR/../../.." && pwd)/target/debug/golem}"
GOLEM_CLI="${GOLEM_CLI_BIN:-$(cd "$SCRIPT_DIR/../../.." && pwd)/target/debug/golem-cli}"
AGENT='CounterAgent("c1")'
SERVER_PID=""
fail() { echo "FAIL: $*"; exit 1; }

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/app-parent" "$WORKDIR/server-data"
(cd "$WORKDIR/app-parent" && "$GOLEM_CLI" new --template kotlin --component-name example:counter --yes app)
APP="$WORKDIR/app-parent/app"
SDK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/sdk"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"; mkdir -p "$APP/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
chmod +x "$APP/gradlew"
cp "$SCRIPT_DIR/contract-tests/CounterAgentSnapshot.kt.fixture" "$(find "$APP" -name CounterAgent.kt | head -1)"

# Start the server, sending its (very noisy) logs to a separate file so this driver's own output
# stays readable. Remove any stale ports-file first: on a RESTART the file persists from the prior
# run, so waiting for it to merely exist would return instantly against a not-yet-ready server.
start_server() {
    rm -f "$WORKDIR/ports.json"
    "$GOLEM" server run --data-dir "$WORKDIR/server-data" --ports-file "$WORKDIR/ports.json" >"$WORKDIR/server.log" 2>&1 &
    SERVER_PID=$!
    # Startup inspects the seven built-in tool components, a few hundred megabytes of WASM, before
    # it writes the ports file; a debug-built server needs minutes. Wait generously and say so,
    # rather than letting the deploy fail confusingly against a server that is merely not ready.
    local waited=0
    while [ ! -s "$WORKDIR/ports.json" ]; do
        kill -0 "$SERVER_PID" 2>/dev/null || fail "golem server exited during startup (see $WORKDIR/server.log)"
        [ "$waited" -lt "${SERVER_WAIT_SECONDS:-600}" ] || fail "golem server not ready after ${SERVER_WAIT_SECONDS:-600}s (see $WORKDIR/server.log)"
        waited=$((waited + 1))
        sleep 1
    done
    echo "   server ready after ${waited}s"
}
stop_server() { [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; } || true; }
trap 'stop_server' EXIT

# Invoke getValue and echo the integer result. Retries: writing the ports-file does not mean the
# executor/registry are ready to serve invokes yet (especially right after a restart), so a fresh
# invoke can transiently error before the value is available. Poll until a bare integer comes back.
get_value() {
    local out val
    for _ in $(seq 1 40); do
        out="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$AGENT" getValue 2>/dev/null)"
        val="$(printf '%s\n' "$out" | grep -oE '^-?[0-9]+$' | tail -1)"
        [ -n "$val" ] && { printf '%s' "$val"; return 0; }
        sleep 1
    done
    printf '%s' "$out"
    return 1
}

CUSTOM_AGENT='CustomSnapshotAgent("c1")'
MULTI_AGENT='MultipartSnapshotAgent("c1")'
LEDGER_AGENT='LedgerAgent("c1")'

# Like get_value, for any agent/method returning a scalar the CLI prints bare or quoted.
read_back() { # read_back <agent> <method> <regex>
    local agent="$1" method="$2" pattern="$3" out val
    for _ in $(seq 1 40); do
        out="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$agent" "$method" 2>/dev/null)"
        val="$(printf '%s\n' "$out" | tr -d '"' | grep -oE "$pattern" | tail -1)"
        [ -n "$val" ] && { printf '%s' "$val"; return 0; }
        sleep 1
    done
    printf '%s' "$out"
    return 1
}

echo "== build + deploy revision 1 =="
(cd "$APP" && "$GOLEM_CLI" build) || fail "build v1"
start_server
(cd "$APP" && "$GOLEM_CLI" deploy --yes) || fail "deploy v1"

echo "== drive state on all four snapshot flavours =="
for i in 1 2 3; do (cd "$APP" && "$GOLEM_CLI" agent invoke "$AGENT" increment) >/dev/null; done
before="$(get_value)"
[ "$before" = "3" ] || fail "typed: expected 3 before update, got '$before'"

# Custom-byte: the agent encodes its own state (5 + 7 = 12).
for by in 5 7; do (cd "$APP" && "$GOLEM_CLI" agent invoke "$CUSTOM_AGENT" add "$by") >/dev/null; done
custom_before="$(read_back "$CUSTOM_AGENT" getTotal '^-?[0-9]+$')"
[ "$custom_before" = "12" ] || fail "custom: expected 12 before update, got '$custom_before'"

# Multipart: state is a list saved as two named parts.
for v in 3 1 4; do (cd "$APP" && "$GOLEM_CLI" agent invoke "$MULTI_AGENT" push "$v") >/dev/null; done
multi_before="$(read_back "$MULTI_AGENT" getHistory '^[0-9,]+$')"
[ "$multi_before" = "3,1,4" ] || fail "multipart: expected 3,1,4 before update, got '$multi_before'"

# Typed state beside the parts: 5 + 7 = 12 in the typed state, 5|7 in a part. The trailing field
# is what `state` held when loadSnapshotParts ran, so "none" is right before any restore.
for by in 5 7; do (cd "$APP" && "$GOLEM_CLI" agent invoke "$LEDGER_AGENT" record "$by") >/dev/null; done
ledger_before="$(read_back "$LEDGER_AGENT" getSummary '^[a-z]+:[0-9]+:[0-9|]*:[a-z]+$')"
[ "$ledger_before" = "recorded:12:5|7:none" ] || fail "ledger: expected recorded:12:5|7:none before update, got '$ledger_before'"

echo "== create revision 2 (patch source + clean + rebuild + redeploy) =="
# Add a new no-op method so the wasm binary changes and the host sees a genuinely new revision.
AGENT_KT="$(find "$APP" -name CounterAgent.kt | head -1)"
# Add a NEW @Endpoint method so the compiled wasm genuinely differs, forcing a new component
# revision. It MUST be an @Endpoint: an unexported/unreferenced method is dead-code-eliminated by
# Kotlin/Wasm, yielding a byte-identical binary and a "no changes required" no-op deploy.
sed -i '' 's|    fun getValue(): Int = state.value|    fun getValue(): Int = state.value\n\n    @Prompt("Get the component revision")\n    @Description("Returns the component revision (2 in revision 2)")\n    @Endpoint(get = "/version")\n    fun getVersion(): Int = 2|' "$AGENT_KT"
# Clean gradle build outputs and the golem-cli build cache so the changed source forces a full rebuild.
rm -rf "$APP/build" "$APP/.gradle" "$APP/golem-temp"
(cd "$APP" && "$GOLEM_CLI" build) || fail "build v2"
(cd "$APP" && "$GOLEM_CLI" deploy --yes) || fail "deploy v2"

echo "== manual (snapshot-based) update: save on old, load on new =="
for agent in "$AGENT" "$CUSTOM_AGENT" "$MULTI_AGENT" "$LEDGER_AGENT"; do
    (cd "$APP" && "$GOLEM_CLI" agent update "$agent" manual --await --yes) || fail "manual update of $agent"
done

echo "== restart server to force reload from snapshot =="
stop_server; start_server

after="$(get_value)"
[ "$after" = "3" ] || fail "typed state not preserved: expected 3, got '$after'"

custom_after="$(read_back "$CUSTOM_AGENT" getTotal '^-?[0-9]+$')"
[ "$custom_after" = "12" ] || fail "custom-byte state not preserved: expected 12, got '$custom_after'"

multi_after="$(read_back "$MULTI_AGENT" getHistory '^[0-9,]+$')"
[ "$multi_after" = "3,1,4" ] || fail "multipart state not preserved: expected 3,1,4, got '$multi_after'"

# The trailing field is now "recorded": the typed state was already restored when the parts hook
# ran. The agent's own part named `state` survived intact, so the state slot did not overwrite it.
ledger_after="$(read_back "$LEDGER_AGENT" getSummary '^[a-z]+:[0-9]+:[0-9|]*:[a-z]+$')"
[ "$ledger_after" = "recorded:12:5|7:recorded" ] ||
    fail "typed state beside parts not preserved: expected recorded:12:5|7:recorded, got '$ledger_after'"

echo "== snapshot e2e PASS =="
echo "   typed Snapshotted<S>     : 3"
echo "   custom bytes             : 12"
echo "   multipart (2 parts)      : 3,1,4"
echo "   typed state beside parts : recorded:12:5|7 (state restored before the parts hook)"
echo "   all four carried through a manual update + a server restart"
