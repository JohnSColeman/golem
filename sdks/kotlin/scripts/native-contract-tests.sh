#!/usr/bin/env bash
# Contract-test harness: scaffold -> build -> deploy -> probe, entirely through the real
# toolchain, swapping the scaffolded CounterAgent for ContractProbeAgent. Proves the
# compiled-Kotlin <-> host ABI boundary for each capability (contract-only: no trap + expected
# shape; NOT functional correctness). Mirrors native-e2e.sh's scaffold/build/server/deploy.
#
# Usage: native-contract-tests.sh <workdir>
# Requires: SDK/KSP/gradle-plugin published to mavenLocal; golem/golem-cli built from this branch.
# GOLEM_BIN/GOLEM_CLI_BIN override the built binary paths.
set -uo pipefail   # NOTE: not -e; a failing probe must not abort the run.

WORKDIR="${1:?workdir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLEM="${GOLEM_BIN:-$(cd "$SCRIPT_DIR/../../.." && pwd)/target/debug/golem}"
GOLEM_CLI="${GOLEM_CLI_BIN:-$(cd "$SCRIPT_DIR/../../.." && pwd)/target/debug/golem-cli}"
FIXTURE="$SCRIPT_DIR/contract-tests/ContractProbeAgent.kt"
# Each probe runs on its OWN durable agent (keyed by the method name) so a wasm trap in one probe
# wedges only that worker -- it can't cascade false FAILs onto later probes via shared-agent
# recovery. (Learned the hard way: a shared "p1" made the oplog trap fail every subsequent probe.)
agent_for() { printf 'ContractProbeAgent("%s")' "$1"; }

PASS=0; FAIL=0; RESULTS=()

record() { # record <label> <verdict> <detail>
  RESULTS+=("$1|$2|$3")
  if [ "$2" = PASS ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

probe() { # probe <label> <method> [args...]
  local label="$1" method="$2"; shift 2
  local out ec
  out="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$(agent_for "$method")" "$method" "$@" 2>&1)"; ec=$?
  if [ $ec -ne 0 ]; then record "$label" FAIL "trap/invoke-error (exit $ec): $(echo "$out" | tail -1)"
  elif echo "$out" | grep -q '"OK'; then record "$label" PASS "$(echo "$out" | grep '"OK' | tail -1)"
  else record "$label" FAIL "no OK in result: $(echo "$out" | tail -1)"; fi
}

probe_json() { # probe_json <label> <method> <grep-pattern>
  local label="$1" method="$2" pat="$3"
  local out ec
  out="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$(agent_for "$method")" "$method" --format json 2>&1)"; ec=$?
  if [ $ec -ne 0 ]; then record "$label" FAIL "trap/invoke-error (exit $ec)"
  elif echo "$out" | grep -Eq "$pat"; then record "$label" PASS "matched /$pat/"
  else record "$label" FAIL "pattern /$pat/ not in result"; fi
}

probe_http() { # probe_http <label> <verb> <path> [grep-pattern] [extra-header]
  local label="$1" verb="$2" path="$3" pat="${4:-OK}" extra="${5:-}"
  local out
  if [ -n "$extra" ]; then
    out="$(curl -s -X "$verb" "http://localhost:$CUSTOM_PORT$path" -H 'Host: app.localhost:9006' -H "$extra")"
  else
    out="$(curl -s -X "$verb" "http://localhost:$CUSTOM_PORT$path" -H 'Host: app.localhost:9006')"
  fi
  if echo "$out" | grep -q "$pat"; then record "$label" PASS "http $verb $path"
  else record "$label" FAIL "http $verb $path -> $out"; fi
}

# probe_expect_hang <label> <bound-seconds> <method> [args...]
#
# For a method with a KNOWN, DOCUMENTED HOST DEFECT that hangs it indefinitely (no trap, no
# error) -- see .superpowers/sdd/2026-11-01-kotlin-wasi-http-and-filesystem/progress.md and the
# matching plan's Task 4 Step 3. Leaving such a probe unregistered only proves the defect once, by
# hand; this instead runs it under a hard timeout every time, so the suite catches a regression
# (or a fix) automatically without ever hanging itself. A timeout is the CURRENT expected (PASS)
# outcome: it proves the defect reproduces deterministically. A clean completion is a loud FAIL
# that says the defect may be fixed and this probe needs to be replaced with a real assertion. Any
# other failure (connection refused, a trap, ...) is also a FAIL: a different, unexpected failure
# mode must never be mistaken for a confirmation of the known defect.
probe_expect_hang() {
  local label="$1" bound="$2" method="$3"; shift 3
  local out ec
  out="$(cd "$APP" && timeout "$bound" "$GOLEM_CLI" agent invoke "$(agent_for "$method")" "$method" "$@" 2>&1)"; ec=$?
  if [ "$ec" -eq 124 ]; then
    record "$label" PASS "known defect reproduced: timed out after ${bound}s (see progress.md 'Task 4' / plan Task 4 Step 3) -- expected to keep timing out until the underlying wasmtime-wasi-http defect is fixed"
  elif [ "$ec" -eq 0 ] && echo "$out" | grep -q '"OK'; then
    record "$label" FAIL "UNEXPECTED: completed in under ${bound}s ($(echo "$out" | grep '"OK' | tail -1)) -- the known host defect may be fixed; replace this probe with a normal pass/fail assertion and re-enable the raw probeHttpSendLargeBody call once confirmed"
  else
    record "$label" FAIL "unexpected failure (not the known-defect timeout, exit $ec): $(echo "$out" | tail -1)"
  fi
}

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/app-parent" "$WORKDIR/server-data"

echo "== scaffold =="
(cd "$WORKDIR/app-parent" && "$GOLEM_CLI" new --template kotlin --component-name example:probe --yes app)
APP="$WORKDIR/app-parent/app"

# Reuse the checked-in gradle wrapper (golem new does not scaffold one for Kotlin).
SDK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/sdk"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"
mkdir -p "$APP/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"
chmod +x "$APP/gradlew"

echo "== swap in probe fixture =="
# Delete the scaffolded CounterAgent and drop the probe into a fresh package dir.
find "$APP" -name 'CounterAgent.kt' -delete
PROBE_DIR="$APP/src/wasmWasiMain/kotlin/contractprobe"
mkdir -p "$PROBE_DIR"
cp "$FIXTURE" "$PROBE_DIR/ContractProbeAgent.kt"
# Point the app's httpApi at the probe agent instead of CounterAgent.
HTTP_YAML="$(grep -rl 'CounterAgent' "$APP" --include=golem.yaml | head -1)"
if [ -n "$HTTP_YAML" ]; then
  perl -0pi -e 's/CounterAgent/ContractProbeAgent/g' "$HTTP_YAML"
  # The router agent types need their own entries in the HTTP deployment, or the gateway has no
  # route to them. Their names are the @HttpRouter typeNames in the fixture.
  perl -0pi -e 's/^(\s+)ContractProbeAgent: \{\}$/$1ContractProbeAgent: {}\n$1ConfigProbeAgent: {}\n$1ProbeApi: {}\n$1ProbeEcho: {}\n$1ProbeSite: {}\n$1ProbeDocsAgent: {}/m' "$HTTP_YAML"
fi

# Agent config (agents.<AgentType>.config) and the environment's quota resource defaults are
# provided by the manifest. Appended with python so the YAML stays valid whatever the template ships.
# Source files for the two Initial File Systems the manifest packages below. sourcePath is
# resolved relative to the manifest's directory.
mkdir -p "$APP/static"
printf 'probe-static-ok\n' > "$APP/static/index.html"
printf 'probe-live-ok\n'   > "$APP/static/latest.txt"
printf 'filesystem contract probe' > "$APP/static/filesystem-probe.txt"

python3 - "$APP/golem.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
assert "components:\n" in text, "components anchor not found"

# Both of these are TOP-LEVEL manifest keys, not members of a component or an environment:
# `agents.<agent-type-name>.config` supplies the per-agent-type config the SDK reads through
# get-config-value, and `resourceDefaults.<environment>.<resource>` declares a quota resource.
# A resource record requires limit (an object), enforcementAction, unit and units.
if "appName: probe-app" not in text:
    text = text.replace(
        "components:\n",
        "agents:\n"
        "  ConfigProbeAgent:\n"
        "    config:\n"
        "      appName: probe-app\n"
        "      db:\n"
        "        host: db.probe\n"
        "        port: 5432\n"
        "  ContractProbeAgent:\n"
        "    files:\n"
        "      - sourcePath: static/filesystem-probe.txt\n"
        "        targetPath: /probe-data/filesystem-probe.txt\n"
        "  ProbeSite:\n"
        "    files:\n"
        "      - sourcePath: static/index.html\n"
        "        targetPath: /site/index.html\n"
        "  ProbeDocsAgent:\n"
        "    files:\n"
        "      - sourcePath: static/latest.txt\n"
        "        targetPath: /public/latest.txt\n"
        "\ncomponents:\n",
        1,
    )

if "resourceDefaults:" not in text:
    text = text.replace(
        "components:\n",
        "resourceDefaults:\n"
        "  local:\n"
        "    probe-resource:\n"
        "      limit: { type: Rate, value: 1000, period: second, max: 2000 }\n"
        "      enforcementAction: throttle\n"
        "      unit: unit\n"
        "      units: units\n"
        "\ncomponents:\n",
        1,
    )

open(path, "w", encoding="utf-8").write(text)
PY
echo "--- manifest after provisioning ---"
sed -n '1,60p' "$APP/golem.yaml" | grep -nE "agents:|ConfigProbeAgent|appName|host:|port:|resourceDefaults|probe-resource" || true

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
  waited=$((waited + 1))
  sleep 1
done
echo "   server ready after ${waited}s"
CUSTOM_PORT="$(grep -o '"customRequestPort": *[0-9]*' "$WORKDIR/ports.json" | grep -o '[0-9]*')"

echo "== deploy =="
(cd "$APP" && "$GOLEM_CLI" deploy --yes) || { echo "DEPLOY FAILED"; exit 2; }

# An external durable-stream peer for probe 34. The executor performs the HTTP, so this has to
# speak the peer side of the protocol; see contract-tests/durable-stream-peer.py.
DS_PORT="${DS_PORT:-19432}"
python3 "$SCRIPT_DIR/contract-tests/durable-stream-peer.py" "$DS_PORT" >"$WORKDIR/ds-peer.log" 2>&1 &
DS_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; kill "$DS_PID" 2>/dev/null || true; kill "$HTTP_PEER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$DS_PORT/appends" >/dev/null 2>&1 && break
  sleep 1
done

# An external HTTP peer for probes 49/50 (outgoing HTTP, `HttpOutgoingClient.send`); see
# contract-tests/http-echo-peer.py. Probe 51 (connection-refused) deliberately targets
# HTTP_REFUSED_PORT, where nothing listens -- confirmed unbound right before the probes run,
# not merely assumed free, since a stray process on that port would turn the negative-path probe
# into a false FAIL.
HTTP_PORT="${HTTP_PORT:-19433}"
HTTP_REFUSED_PORT="${HTTP_REFUSED_PORT:-19434}"
python3 "$SCRIPT_DIR/contract-tests/http-echo-peer.py" "$HTTP_PORT" >"$WORKDIR/http-peer.log" 2>&1 &
HTTP_PEER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; kill "$DS_PID" 2>/dev/null || true; kill "$HTTP_PEER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf -X POST "http://127.0.0.1:$HTTP_PORT/echo" >/dev/null 2>&1 && break
  sleep 1
done
if curl -sf "http://127.0.0.1:$HTTP_REFUSED_PORT/" >/dev/null 2>&1; then
  echo "HTTP_REFUSED_PORT $HTTP_REFUSED_PORT is unexpectedly in use -- picking a different port would require a code change; failing loudly instead of producing a false FAIL/PASS on probe 51"
  exit 2
fi

echo "== probes =="
probe      "1 agent-model"  probeAgentModel
probe_http "1 http-gateway" POST "/probe/p1/http-echo"

# NOTE: Kotlin has its own value dialect in golem-cli since 1.6.0 (agent_id_display/parse_kotlin.rs),
# so args are KOTLIN literals, not the old TypeScript fallback: an anonymous record is
# { field = value } with Kotlin '=' (a NAMED data class would be Name(field = value)), a list is
# [a,b,c], and option-some is the bare value. The WAVE/structural forms ((3,4), s(5)) are rejected.
probe_json "2 type-lower"     returnAllTypes 'hello'
probe_json "2 type-lower-num" returnAllTypes '(-64|64)'
probe      "2 type-lift-rec"  echoRecord '{ x = 3, y = 4 }'
probe      "2 type-lift-list" echoList   '[1,2,3]'
probe      "2 type-lift-opt"  echoOpt    '5'

probe "3 host-api" probeHostApi
probe "4 oplog"    probeOplog
probe "5 retry-dsl" probeRetry
probe "6 transactions" probeTransactions
probe "7 guards"        probeGuards

# Secrets: PASS on clean SecretError (OK) OR host trap (invalid handle rejected); only a silent
# value return is a real FAIL. Custom classification (not the standard probe helper).
{
  out="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$(agent_for probeSecrets)" probeSecrets 2>&1)"; ec=$?
  if [ $ec -ne 0 ]; then record "8 secrets" PASS "host rejected invalid handle (trap): $(echo "$out" | tail -1)"
  elif echo "$out" | grep -q 'OK'; then record "8 secrets" PASS "$(echo "$out" | grep 'OK' | tail -1)"
  else record "8 secrets" FAIL "silent value return: $(echo "$out" | tail -1)"; fi
}
probe "9 context" probeContext
probe "10 durability" probeDurability
probe "11 rpc"              probeRpc
probe "12 agent-reflection" probeReflection
probe "13 tools"            probeTools
probe "14 key-value"        probeKeyValue
probe "46 key-value streaming" probeKeyValueStreaming
probe "15 blobstore"        probeBlobstore
probe "16 rdbms"            probeRdbms
probe "17 wasi env/config"  probeWasi
probe "18 permission-cards" probePermissions
probe "19 promises"         probePromises
probe "20 websocket"        probeWebsocket
probe_json "21 schema-corners" probeSchemaCorners 'probe'
# The same corners nested in option and result, recorded as unsupported (#4105). The probe decides it.
probe_json "45 nested schema-corners" probeNestedCorners 'nested'

# --- HTTP serving over the local gateway (spike: the "needs the worker service" exclusion) ---
probe_http "22 http header+query" GET "/probe/p1/bound?q=hello" "OK bound q=hello tenant=acme" "X-Tenant: acme"
# The provider's document is merged into the deployment's OpenAPI document, which the worker
# service serves at the reserved /openapi.json path -- not at the router's own mount.
probe_http "23 http openapi-provider" GET "/openapi.json" "openapi"
probe_http "24 http custom-handler" GET "/probe-echo/any/path" "OK handler"
probe "25 quota" probeQuota
probe "47 filesystem" probeFilesystem
probe "48 filesystem large-file" probeFilesystemLargeFile 5
probe "49 http send" probeHttpSend "$HTTP_PORT"
# Capability 50 (probeHttpSendLargeBody, same fixture method): a multi-MB outgoing request body
# hangs `client.send` indefinitely -- a documented, root-caused host defect in vendored
# wasmtime-wasi-http's GuestBody stream consumption (not golem-worker-executor's own code; see
# progress.md's "Task 4" sections). Run as a bounded regression probe via probe_expect_hang: 20s is
# comfortably more than a working 1 MB loopback send would ever need (sub-second), so there is no
# ambiguity between "slow" and "still broken," and the suite never hangs on it.
probe_expect_hang "50 http send-large (known defect)" 20 probeHttpSendLargeBody "$HTTP_PORT" 1
probe "51 http connection-error" probeHttpConnectionError "$HTTP_REFUSED_PORT"
probe_http "32 router static file" GET "/probe-site/" "probe-static-ok"
# Guest-to-guest duplex streams relay a stream argument to a stream result between two agents.
# Run under a hard timeout so that a hang fails the probe instead of stalling the suite; a timeout
# is never a pass. The host brokers the relay, so neither side blocks the other.
duplex_out="$(cd "$APP" && timeout 60 "$GOLEM_CLI" agent invoke 'ContractProbeAgent("probeDuplexStream")' probeDuplexStream 2>&1)"; duplex_ec=$?
if [ "$duplex_ec" -eq 124 ]; then
  record "36 duplex streams" FAIL "timed out after 60s waiting for the relay"
elif printf '%s' "$duplex_out" | grep -q '"OK'; then
  record "36 duplex streams" PASS "$(printf '%s' "$duplex_out" | grep '"OK' | tail -1)"
else
  record "36 duplex streams" FAIL "$(printf '%s' "$duplex_out" | tail -1)"
fi

# The write-first shape: the callee emits a prologue before it drains its argument, so a write
# completes with no reader present. Under the same hard timeout -- a hang is a failure, not a pass.
wf_out="$(cd "$APP" && timeout 60 "$GOLEM_CLI" agent invoke 'ContractProbeAgent("probeDuplexWriteFirst")' probeDuplexWriteFirst 2>&1)"; wf_ec=$?
if [ "$wf_ec" -eq 124 ]; then
  record "37 duplex write-first" FAIL "timed out after 60s waiting for the prologue"
elif printf '%s' "$wf_out" | grep -q '"OK'; then
  record "37 duplex write-first" PASS "$(printf '%s' "$wf_out" | grep '"OK' | tail -1)"
else
  record "37 duplex write-first" FAIL "$(printf '%s' "$wf_out" | tail -1)"
fi

# Stream edge cases. Each goes through RPC to a sibling agent, so each exercises a real
# host-brokered stream rather than a local object. Timed out individually: a hang is a failure.
for edge in "38 empty stream:probeEmptyStream" \
            "39 abandoned reader:probeAbandonedReader" \
            "40 throwing producer:probeThrowingProducer" \
            "41 record-element stream:probeRecordStream" \
            "42 concurrent duplex:probeConcurrentDuplex"; do
  label="${edge%%:*}"; method="${edge##*:}"
  out="$(cd "$APP" && timeout 60 "$GOLEM_CLI" agent invoke "$(agent_for "$method")" "$method" 2>&1)"; ec=$?
  if [ "$ec" -eq 124 ]; then
    record "$label" FAIL "timed out after 60s"
  elif printf '%s' "$out" | grep -q '"OK'; then
    record "$label" PASS "$(printf '%s' "$out" | grep '"OK' | tail -1)"
  else
    record "$label" FAIL "$(printf '%s' "$out" | tail -1)"
  fi
done

# The collection caps, at their boundary, on a live host. Unit tests in `TallyTest` cover the
# arithmetic; these show that refusing mid-read neither traps the agent nor wedges the source.
probe "43 stream element cap" probeStreamItemCap
probe "44 blobstore name cap" probeBlobstoreNameCap

probe "34 durable streams" probeDurableStream "\"http://127.0.0.1:$DS_PORT/stream\""

# What the peer actually received. Parsed rather than grepped: the body is JSON inside JSON, so
# the message arrives as \"probe\" and a substring match on '"probe"' silently never matches.
ds_appends="$(curl -s "http://127.0.0.1:$DS_PORT/appends" || echo '[]')"
ds_verdict="$(printf '%s' "$ds_appends" | python3 -c '
import json, sys
try:
    attempts = json.load(sys.stdin)
except Exception as error:
    print("FAIL unparseable peer log: %s" % error); raise SystemExit
if len(attempts) != 1:
    print("FAIL expected exactly one append, got %d" % len(attempts)); raise SystemExit
a = attempts[0]
if json.loads(a["body"]) != ["probe"]:
    print("FAIL body was %r" % a["body"]); raise SystemExit
if not a["close"]:
    print("FAIL close flag was not set"); raise SystemExit
if (a["epoch"], a["sequence"]) != ("0", "0"):
    print("FAIL producer tuple was epoch=%s seq=%s" % (a["epoch"], a["sequence"])); raise SystemExit
print("PASS one append, body [\"probe\"], close=true, epoch=0 seq=0, producer=%s" % a["producer"][:16])
')"
case "$ds_verdict" in
  PASS*) record "35 durable stream append" PASS "${ds_verdict#PASS }" ;;
  *)     record "35 durable stream append" FAIL "${ds_verdict#FAIL }" ;;
esac
probe_http "33 agent live file"    GET "/probe-docs/d1/latest" "probe-live-ok"
probe "27 tool-call"       probeToolCall
probe "28 card-ops"        probeCardOps
probe "29 dynamic-client"  probeDynamicClient
probe "30 webhook"         probeWebhook
# An unstructured text is an ANONYMOUS variant, so the case takes no type prefix, and a `text`
# payload renders as a positional rich constructor: Inline(Text("<text>", "<language>")).
# The language must be in the @Languages allow-list or the host rejects the call before the body.
probe "31 allow-list"      probeAllowList 'Inline(Text("note", "en"))'

# Agent config lives on its own agent type, so it needs its own invoke target.
config_out="$(cd "$APP" && "$GOLEM_CLI" agent invoke 'ConfigProbeAgent("c1")' readConfig 2>&1)"
if echo "$config_out" | grep -q '"OK'; then
  record "26 agent-config" PASS "$(echo "$config_out" | grep '"OK' | tail -1)"
else
  record "26 agent-config" FAIL "$(echo "$config_out" | tail -1)"
fi

# Not probed here, and deliberately:
#   tool middleware - an installed middleware chain over a provider tool. The executor suite covers
#                     it, including crash replay of a wrapped call, in
#                     golem-worker-executor/tests/tool_streaming/middleware_acceptance.rs. A
#                     middleware reaches the next layer only through underlying-tool.invoke, whose
#                     durability the host owns, so a Kotlin chain adds no coverage this driver lacks.

# (later tasks append probe rows here)

echo ""
echo "==================== CONTRACT TEST RESULTS ===================="
for r in "${RESULTS[@]}"; do
  IFS='|' read -r label verdict detail <<< "$r"
  printf '  %-4s %-22s %s\n' "$verdict" "$label" "$detail"
done
echo "--------------------------------------------------------------"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
