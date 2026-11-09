#!/usr/bin/env bash
# Runs the generated Kotlin bridges on a real executor. A Kotlin consumer component calls a Kotlin `Calculator` agent and Rust tools through the guest
# clients `golem build` generates from its dependencies; a plain JVM program calls the `Calculator` through the external REST client
# `golem-cli generate-bridge` writes. The script invokes both and checks every result.
#
# Needs a Golem built from this tree (`cargo build -p golem -p golem-cli`), the SDK, KSP processor and Gradle plugin published to mavenLocal
# (`../tool-typed-middleware/build.sh` does that), and java 17+. Uses the server on localhost:9881 when one is running, else starts a throwaway
# one. Exits non-zero on any mismatch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
GOLEM="${GOLEM_BIN:-$ROOT/target/debug/golem}"
GOLEM_CLI="${GOLEM_CLI_BIN:-$ROOT/target/debug/golem-cli}"
APP="$HERE/app"

health() { [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:9881/healthcheck)" = 200 ]; }

if ! health; then
  DATA="$(mktemp -d)"
  "$GOLEM" server run --data-dir "$DATA" >"$DATA/server.log" 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 60); do health && break; sleep 2; done
  health || { echo "server did not become healthy; see $DATA/server.log" >&2; exit 1; }
fi

SDK_DIR="$ROOT/sdks/kotlin/sdk"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$APP/"
mkdir -p "$APP/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$APP/gradle/wrapper/"

(cd "$APP" && "$GOLEM_CLI" deploy --yes --force-build)

failures=0
RUN="r$$"

# expect AGENT METHOD WANT ARG...: invokes AGENT("$RUN").METHOD with the ARGs (Kotlin syntax) and compares the printed result with WANT.
expect() {
  local agent="$1" method="$2" want="$3" got
  shift 3
  got="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$agent(\"$RUN\")" "$method" "$@" 2>&1 | grep -A1 'Kotlin syntax' | tail -1 || true)"
  if [ "$got" = "\"$want\"" ]; then
    echo "ok   $agent $method $* -> $got"
  else
    echo "FAIL $agent $method $* -> $got (want \"$want\")" >&2
    failures=$((failures + 1))
  fi
}

expect BridgeCaller add 7 3 4
expect BridgeCaller accumulate 5 5
expect BridgeCaller accumulate 11 6
expect BridgeCaller move 'MoveInP(x=11, y=22)' 10 20
expect BridgeCaller describe 'circle(2.5)/BLUE,rect(2x3),empty/RED' 2.5
expect BridgeCaller stats '{count=3, sum=6}'
expect BridgeCaller safeDivide 'right:5' 10 2
expect BridgeCaller safeDivide 'left:division by zero' 1 0
expect BridgeCaller wide '7/18446744073709551615/1.5'
expect BridgeCaller asyncAdd 42 20 22
expect BridgeCaller label "calc-$RUN"
expect BridgeCaller trigger triggered
# The callee sees the calling agent, with its component id, as its principal.
expect BridgeCaller caller "agent:BridgeCaller(\\\"$RUN\\\"):true"

expect ToolBridgeCaller search 'search(pattern=foo paths=x/y max=3 ctx=5 inc=a/b cs=true v=2)' '"foo"'
expect ToolBridgeCaller searchDefaults 'search(pattern=foo paths= max=none ctx=2 inc= cs=false v=0)' '"foo"'
expect ToolBridgeCaller gitAdd 'add(name=origin url=https://example.invalid/repo verbose=true dir=d1)' '"origin"'
expect ToolBridgeCaller gitList origin
expect ToolBridgeCaller upper 'HELLO STDIN|11' '"hello stdin"'

# The external client: a plain JVM program outside Golem calls the deployed Calculator over REST through the generated Kotlin client.
GEN="$(mktemp -d)"
(cd "$APP" && "$GOLEM_CLI" generate-bridge --language kotlin --agent-type-name Calculator --output-dir "$GEN")
EXTERNAL="$HERE/external"
cp "$SDK_DIR/gradlew" "$SDK_DIR/gradlew.bat" "$EXTERNAL/"
mkdir -p "$EXTERNAL/gradle/wrapper"
cp "$SDK_DIR/gradle/wrapper/gradle-wrapper.jar" "$SDK_DIR/gradle/wrapper/gradle-wrapper.properties" "$EXTERNAL/gradle/wrapper/"
external_output="$(cd "$EXTERNAL" && ./gradlew --console=plain -q "-PbridgeClient=$GEN/calculator-client" run --args="$RUN")"

# expect_external NAME WANT: compares the NAME=VALUE line the external program printed.
expect_external() {
  local name="$1" want="$2" got
  got="$(printf '%s\n' "$external_output" | grep "^$name=" | head -1 | cut -d= -f2-)"
  if [ "$got" = "$want" ]; then
    echo "ok   external $name -> $got"
  else
    echo "FAIL external $name -> $got (want $want)" >&2
    failures=$((failures + 1))
  fi
}

expect_external add 7
expect_external accumulate '5,11'
expect_external move 'MoveInP(x=11, y=22)'
expect_external describe 'circle(2.5)/BLUE,rect(2x3),empty/RED'
expect_external stats '{count=3, sum=6}'
expect_external safeDivide 'right:5,left:division by zero'
expect_external wide '7/18446744073709551615/1.5'
expect_external asyncAdd 42
expect_external label "ext-$RUN"
expect_external agentId "Calculator(\"ext-$RUN\")"
expect_external trigger ok
expect_external schedule ok
expect_external phantomLabel "ext-$RUN"
expect_external phantomDistinct true

# Per-request authentication: the deployment accepts a test session in a header instead of an identity provider. An endpoint with
# `auth = true` must reject a request without a session, and must hand the session's identity to the agent as its principal.
http_check() {
  local name="$1" want_status="$2" want_body="$3"; shift 3
  local out status body
  out="$(curl -s -m 30 -w '\n%{http_code}' "$@")"
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$status" = "$want_status" ] && [[ "$body" == *"$want_body"* ]]; then
    echo "ok   http $name -> $status $body"
  else
    echo "FAIL http $name -> $status $body (want $want_status containing '$want_body')" >&2
    failures=$((failures + 1))
  fi
}
SECURED="http://localhost:9006/secured/$RUN"
http_check "open without a session" 200 'open:anonymous' "$SECURED/open"
http_check "authenticated endpoint without a session" 401 '' "$SECURED/me"
http_check "authenticated endpoint with a session" 200 'me:oidc:bob:bob@golem.cloud' \
  -H 'x-golem-test-session: {"subject": "bob", "email": "bob@golem.cloud"}' "$SECURED/me"
# An endpoint without `auth` does not resolve the session: its principal stays anonymous.
http_check "open endpoint ignores the session" 200 'open:anonymous' \
  -H 'x-golem-test-session: {"subject": "bob", "email": "bob@golem.cloud"}' "$SECURED/open"

if [ "$failures" -ne 0 ]; then
  echo "$failures bridge check(s) failed" >&2
  exit 1
fi
echo "bridge checks passed"
