# Contract-test harness

`../native-contract-tests.sh <workdir>` scaffolds a Kotlin app, swaps in `ContractProbeAgent`,
builds/deploys it to a locally built golem server, and invokes one probe per capability to prove
the compiled-Kotlin ⇄ host ABI boundary works.

**Scope: contract-only.** Each probe proves a host call crossed the boundary and returned the
expected *shape* without trapping — not that the value is functionally correct. Durability's
persist-then-replay behaviour is out of scope (the durability probe proves only that the
durable-function imports marshal). Agent snapshotting is covered by `native-snapshot-e2e.sh`, so it is intentionally
not re-probed here.

Each probe runs on its **own durable agent** (keyed by the method name) so a wasm trap in one probe
wedges only that worker and can't cascade false FAILs onto later probes.

Prerequisites (same as `native-e2e.sh`): SDK/KSP/gradle-plugin published to mavenLocal, and
`golem`/`golem-cli` built from this branch. On a machine whose default `java` is < 17, point
`JAVA_HOME` at a 17+ JDK for the gradle build. Exit 0 iff every probe passed.

Kotlin arguments use the **Kotlin** value dialect, not the TypeScript fallback (see
`cli/golem-cli/src/agent_id_display/render_kotlin.rs`). An **anonymous** record takes Kotlin `=`,
`{ x = 3, y = 4 }`, and a **named** data class takes constructor form, `Pt(x = 3, y = 4)`. Note
that a data class used only as a parameter type is usually rendered anonymously, so `{ x = 3 }` is
the common case. Lists are `[a,b,c]`; option-some is the bare value.

A probe's verdict is matched on `"OK` — the leading quote matters, because the agent's verdict is
rendered as a quoted string and a bare `OK` also matches the CLI's own progress output. Matching
loosely once reported a PASS for a probe that was returning `FAIL`.

Capabilities probed (26): agent model, type mapping (lower + lift), host API, oplog, retry DSL,
transactions, guards, secrets, context/tracing, durability, RPC, agent reflection, tools, WASI
key-value, WASI blobstore, RDBMS, WASI environment/config/logging, permission cards, promises,
WebSocket client, the 1.6.0 schema corners (uuid, `kotlin.time.Duration`, bytes, unstructured),
three request-time HTTP paths (`@Header` + `?q={}` endpoint bindings, the `@OpenApiProvider`
document, and a custom `@HttpHandler`), quota, agent config, WASI filesystem (preview 3:
reads an IFS-declared file, confirms a missing path comes back as a typed error, and writes +
reads back a brand-new path under the unconditionally-preopened `/` root), and WASI outgoing HTTP
(preview 3, `wasi:http/client.send`: a real request/response round-trip against a local peer
process, and a refused connection decoding to its own `HttpErrorCode` case). A third outgoing-HTTP
probe for a multi-MB body exists in the fixture but is deliberately not run here: a multi-MB
*request* body hangs `client.send` indefinitely, a known, unresolved host-side issue (see
`sdks/kotlin/sdk/.../wasi/Http.kt`'s own header doc comment) -- registering it would hang this
script forever on every future run.

Three are negative-path probes by necessity: nothing here provisions a database or a WebSocket
peer, so RDBMS and WebSocket prove that a refused connection returns a typed error instead of
trapping the agent; the outgoing-HTTP suite's own connection-error probe does the same thing
deliberately, against a port the driver confirms is unbound right before the probe runs. That is
the contract this suite exists to check.

The `tools` probe asserts the **default grant** rather than "non-empty". The registry provisions
seven built-in tools, but access is bound per agent type (`ToolBindingOwner::AgentType`) and this
app declares no tool dependencies, so the agent sees `golem-common`'s `DEFAULT_TOOLS` — `bash`
alone. Asserting the exact grant is what would catch a decode that silently drops entries.

The OpenAPI document is served at the reserved **`/openapi.json`**, not at the router's own mount:
a provider method's output is merged into the deployment document.

The driver provisions what the deployment must supply: `agents.<AgentType>.config` for the config
probe and `resourceDefaults.<env>.<resource>` for the quota probe. **Both are top-level manifest
keys**, not members of a component or an environment, and a resource record requires `limit` (an
object), `enforcementAction`, `unit` and `units`.

**Not probed here.** This list used to include request-time HTTP serving ("needs the worker
service"), agent config and quota ("needs the deployment to provide it"). All three were stale: the
local server serves those routes, and the manifest can provision config and a quota resource. What
genuinely remains outside this driver:

| Capability | What it needs |
|---|---|
| Router static bindings, `@Agent(exposeFiles)` live files | files packaged into the component; the serving path itself is proven by the handler probe |
| External durable streams | a peer HTTP server to read from and append to |
| Schema streams between two guest peers | a concurrent peer — two *blocking* peers deadlock. The HTTP bridge is such a peer, and the `@HttpHandler` probe exercises a guest-produced stream through it |
**Covered by a sibling script, not absent:** tool middleware, including typed `@ToolDefinition` /
`@Arg` middleware, runs against a real executor in
`sdks/kotlin/scripts/tool-typed-middleware/executor/run.sh`. Custom-byte and multipart snapshots
are the one capability with no reproducible coverage anywhere in the tree —
`native-snapshot-e2e.sh` exercises typed `Snapshotted<S>` only.

## Arena headroom check (a second, separate app)

`../native-headroom-tests.sh <workdir>` builds a second small app, with `HeadroomProbeAgent` and
`wasmComponent { arenaHeadroomKiB.set(256) }`, so this suite keeps covering the default headroom. Four checks,
each failing if the setting did not take effect: the arena starts at the headroom (read inside the agent with
`alloc(0, 1)`), a `println` of three quarters of the headroom succeeds, the printing agent is still usable
afterwards (the canary is intact), and an agent's linear memory is at most the headroom plus five pages
(`golem agent get`). `HEADROOM_KIB` changes the setting; `HEADROOM_APPLY=0` builds without it while still
expecting it, which must fail the first and last checks. A print over the headroom fails the agent by design and is
covered by `MemoryTest`, because a probe cannot expect a trap.
