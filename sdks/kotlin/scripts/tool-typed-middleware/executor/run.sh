#!/usr/bin/env bash
# Runs the typed middleware on a real executor: deploys a Rust leaf provider (tools `middleware-probe` and `backend-probe`) and a Kotlin
# component with a transparent middleware, an adapter and two caller agents, then calls through both middleware chains and checks the results.
#
# Needs a Golem built from this tree (`cargo build -p golem -p golem-cli`, with its built-in tool artifacts), the SDK, KSP processor and Gradle
# plugin published to mavenLocal (`../build.sh` does that), java 17+, and the Rust toolchain/WASI SDK the Rust provider needs. Uses the server on
# localhost:9881 when one is running, else starts a throwaway one. Exits non-zero on any mismatch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
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
expect() {
  local agent="$1" method="$2" arg="$3" want="$4" got
  got="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$agent" "$method" "\"$arg\"" 2>&1 | grep -A1 'Kotlin syntax' | tail -1)"
  if [ "$got" = "\"$want\"" ]; then
    echo "ok   $agent $method $arg -> $got"
  else
    echo "FAIL $agent $method $arg -> $got (want \"$want\")" >&2
    failures=$((failures + 1))
  fi
}

RUN="r$$"
expect "ProbeCaller(\"$RUN\")" probe x 'mw(leaf(audit(x)))'
expect "ProbeCaller(\"$RUN\")" check good 'ok(good)'
expect "ProbeCaller(\"$RUN\")" check bad 'declared:Rejected(message=bad sku)'
expect "AdaptedCaller(\"$RUN\")" probe hi 'adapted(6)'
expect "AdaptedCaller(\"$RUN\")" check good 'adapter-check:good'
expect "AdaptedCaller(\"$RUN\")" check bad 'declared:Rejected(message=adapter says no)'

expect "ArgCaller(\"$RUN\")" search foo 'mw(search(pattern=foo paths=x/y max=3 ctx=5 inc=a/b cs=true v=2))'
expect "ArgCaller(\"$RUN\")" searchDefaults foo 'mw(search(pattern=foo paths= max=none ctx=2 inc= cs=false v=0))'
# expect_pair AGENT METHOD ARG1 ARG2 WANT: like `expect` with two string arguments, and the printed result need only contain WANT.
expect_pair() {
  local agent="$1" method="$2" first="$3" second="$4" want="$5" got
  got="$(cd "$APP" && "$GOLEM_CLI" agent invoke "$agent" "$method" "\"$first\"" "\"$second\"" 2>&1 | grep -A1 'Kotlin syntax' | tail -1 || true)"
  if [[ "$got" == *"$want"* ]]; then
    echo "ok   $agent $method $first $second -> $got"
  else
    echo "FAIL $agent $method $first $second -> $got (want it to contain '$want')" >&2
    failures=$((failures + 1))
  fi
}
# The host validates the call's input against the schema the middleware presents, including the refinements the interface declares.
expect_pair "RefinedCaller(\"$RUN\")" bounded 5 abc 'bounded(level=5 ratio=0.5 tag=abc)'
expect_pair "RefinedCaller(\"$RUN\")" bounded 11 abc 'level\") is out of range (above maximum 10)'
expect_pair "RefinedCaller(\"$RUN\")" bounded 0 abc 'level\") is out of range (below minimum 1)'
expect_pair "RefinedCaller(\"$RUN\")" bounded 5 ABC 'does not match required regex'
expect_pair "RefinedCaller(\"$RUN\")" bounded 5 a 'below min-length 2'
expect_pair "RefinedCaller(\"$RUN\")" bounded 5 abcdefghi 'above max-length 8'
expect "RefinedCaller(\"$RUN\")" describe bounded 'level:s32:min=1:max=10:len=null-null:re=null;ratio:f64:min=0.25:max=2.0:len=null-null:re=null;tag:text:min=null:max=null:len=2-8:re=^[a-z]+$'

expect "ArgCaller(\"$RUN\")" upper 'hello stdin' 'HELLO STDIN|11'

expect "ArgCaller(\"$RUN\")" gitAdd origin 'mw(add(name=origin url=https://example.invalid/repo verbose=true dir=d1))'
expect "ArgCaller(\"$RUN\")" describe arg-probe 'POSITIONAL:pattern:FIXED:string:short=null:default=null:required=true;TAIL:paths:TAIL:string:short=null:default=null:required=false;OPTION:max-count:OPTIONAL_SCALAR:s32:short=m:default=null:required=false;OPTION:context:SCALAR:s32:short=null:default=S32(v=2):required=false;OPTION:include:REPEATABLE_LIST:string:short=null:default=null:required=false;FLAG:case-sensitive:BOOL_FLAG:null:short=c:default=null:required=false;FLAG:verbose:COUNT_FLAG:null:short=null:default=null:required=false|formatters=[json, table]/json|constraints=[RequiresAll(refs=[ToolRef(name=pattern, value=null)])]'

expect "KtToolsCaller(\"$RUN\")" lookup ok 'ok'
expect "KtToolsCaller(\"$RUN\")" lookup '' 'custom:not-found:TupleVal(items=[])'
expect "KtToolsCaller(\"$RUN\")" lookup abcdefghij 'custom:over-limit:Record(fields=[S32(v=8), Str(v=too long)])'
expect "KtToolsCaller(\"$RUN\")" upperAsync hello 'HELLO|done:5|5'
# A stream well past the 16 MiB capture ceiling: the capture stops there and reports it, and the tool still reads all of its stdin. Before
# the readable end was released at the ceiling this call never returned, because the tool blocked writing stdout past the host's buffer.
expect "KtToolsCaller(\"$RUN\")" upperN 50331648 'stdout=16777216|stdoutFailure=ResourceExhausted|stderr=done:50331648|total=50331648'
expect "KtToolsCaller(\"$RUN\")" getAll k 'k,custom:not-found:TupleVal(items=[])'
expect "KtToolsCaller(\"$RUN\")" fire hello 'admitted'

want_remote='POSITIONAL:name:FIXED:string:short=null:default=null:required=true;POSITIONAL:url:FIXED:string:short=null:default=null:required=true|formatters=[default]/default|constraints=[]'
got_remote="$(cd "$APP" && "$GOLEM_CLI" agent invoke "KtToolsCaller(\"$RUN\")" describeRust '"remote"' '"add"' 2>&1 | grep -A1 'Kotlin syntax' | tail -1)"
if [ "$got_remote" = "\"$want_remote\"" ]; then
  echo "ok   KtToolsCaller describeRust remote add -> $got_remote"
else
  echo "FAIL KtToolsCaller describeRust remote add -> $got_remote (want \"$want_remote\")" >&2
  failures=$((failures + 1))
fi

# A webhook completes a promise: create the URL, await the payload in the background, POST to the URL, and compare what the agent returned.
invoke_plain() {
  (cd "$APP" && "$GOLEM_CLI" agent invoke "$1" "$2" 2>&1 | grep -A1 'Kotlin syntax' | tail -1)
}
WEBHOOK="WebhookCaller(\"$RUN\")"
hook_url="$(invoke_plain "$WEBHOOK" create | tr -d '"')"
if [ -z "$hook_url" ]; then
  echo "FAIL $WEBHOOK create returned no webhook url" >&2
  failures=$((failures + 1))
else
  AWAITED="$(mktemp)"
  invoke_plain "$WEBHOOK" awaitPayload >"$AWAITED" &
  AWAIT_PID=$!
  sleep 5
  curl -s -m 20 -o /dev/null -X POST -H 'content-type: text/plain' --data 'webhook-body' "$hook_url"
  wait "$AWAIT_PID"
  got="$(cat "$AWAITED")"
  if [ "$got" = '"webhook-body"' ]; then
    echo "ok   $WEBHOOK create/awaitPayload -> $got"
  else
    echo "FAIL $WEBHOOK awaitPayload -> $got (want \"webhook-body\")" >&2
    failures=$((failures + 1))
  fi
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed" >&2; exit 1; }
echo "executor checks passed"
