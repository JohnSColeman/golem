# Kotlin SDK scripts

Everything here is tooling around the Kotlin SDK. **None of it is needed to use the SDK**: an application depends on
the published `sdk`, `ksp` and `gradle-plugin` artifacts and scaffolds with `golem new --template kotlin`.

The entries fall into four classes. Find yours by what you want to do.

| Class | Question it answers | Entries |
|---|---|---|
| [A. Maintenance tooling](#a-maintenance-tooling) | Is a committed, generated source still in step with the WIT? | `gen-oplog.py`, `gen-schema-tags.py` |
| [B. End-to-end drivers](#b-end-to-end-drivers) | Does the built toolchain run a Kotlin component on a real executor? | `native-e2e.sh`, `native-snapshot-e2e.sh`, `native-contract-tests.sh` (+ `contract-tests/`), `bridge/`, `tool-typed-middleware/`, `real-sdk-compile/`, `real-plugin-build/` |
| [C. Acceptance fixtures](#c-acceptance-fixtures-source-only) | What agent source was used to verify feature X? | 11 directories of `.kt` files |
| [D. Diagnostics](#d-diagnostics) | Which host imports does a compiled agent need that the world lacks? | `check-imports.py` |

The class decides where an entry belongs when the work is split into commits or branches:
**A is part of the product** (it maintains committed sources), **B and D are delivery verification**, and **C is evidence
that the API docs cite** (see its section before moving it).

## Prerequisites shared by class B

- A Golem built from this tree: `cargo build -p golem -p golem-cli`. The host must have WasmGC, function references and
  exceptions enabled (`golem-common/src/wasmtime_config.rs`). `GOLEM_BIN` and `GOLEM_CLI_BIN` override the binary paths
  (default `target/debug/golem`, `target/debug/golem-cli`).
- The SDK, KSP processor and Gradle plugin published to mavenLocal at the snapshot version:
  `for m in sdk ksp gradle-plugin; do (cd sdks/kotlin/$m && ./gradlew --no-daemon -PgolemSdkVersion=0.0.0-SNAPSHOT publishToMavenLocal); done`
  (`tool-typed-middleware/build.sh` does this too). Do not export `GOLEM_KOTLIN_SDK_VERSION`; the CLI resolves
  `0.0.0-SNAPSHOT` by itself.
- Java 17 or newer **on `PATH`**, not only in `JAVA_HOME`: `golem build` probes `java` on `PATH`. Network access on the
  first run (it fetches the WASI adapter). `curl` and `wasm-tools` on `PATH`.
- Free disk space. A debug `target/` plus Gradle caches is large.

Two behaviours to know before you run anything:

- The `native-*.sh` scripts take a `<workdir>` and **`rm -rf` it first**. Pass a scratch directory, never one that holds
  data. Each starts its own server with its data under `<workdir>/server-data`.
- `bridge/run.sh` and `tool-typed-middleware/executor/run.sh` **reuse a server already listening on `localhost:9881`**
  and deploy into it. With none running they start a throwaway server on a `mktemp` directory.

---

## A. Maintenance tooling

`cargo make wit` mirrors the repository's `wit/deps` into `wit-native/deps`, and `cargo make check-wit` fails when the
mirror is stale. After a WIT change, run these two generators, in this order. Both support `--check`, which fails
instead of writing; `cargo make check-sdk-kotlin-generated` runs both checks.

| Script | What it does | Run |
|---|---|---|
| `gen-schema-tags.py` | Generates `sdk/src/wasmWasiMain/kotlin/cloud/golem/wasm/SchemaTags.kt` from `golem-core-v2.wit`. A variant case's canonical-ABI tag is its declaration position, so a case inserted mid-variant shifts every later tag; the numbers must never be written by hand. | `scripts/gen-schema-tags.py [--check]` |
| `gen-oplog.py` | Generates `sdk/src/wasmWasiMain/kotlin/cloud/golem/runtime/host/OplogEntries.kt`: layout (sizes, alignments, offsets) and lift code for the ~50-case `public-oplog-entry` variant, derived from the resolved WIT. Types that already have a hand-written Kotlin counterpart are mapped onto it (`OVERRIDES`). Needs `wasm-tools`. | `scripts/gen-oplog.py [--check]` |

---

## B. End-to-end drivers

Each driver goes through the real toolchain and fails loudly. None is a unit test; the unit suites live under
`sdk/src/wasmWasiTest` and `ksp/src/test`.

### `native-e2e.sh <workdir>`

Scaffold → build → deploy → invoke, with no hand-built component and no manual `golem.yaml` edit:
`golem new --template kotlin`, `golem build`, `golem deploy`, `golem agent invoke` against a fresh local server.
The smallest proof that the whole chain works. Exits non-zero on the first failed step.

### `native-snapshot-e2e.sh <workdir>`

Host-level snapshot round trip. Scaffolds an app, replaces its `CounterAgent` with
`contract-tests/CounterAgentSnapshot.kt.fixture`, and checks that the worker executor calls the guest's
`save-snapshot` on the old revision and `load-snapshot` on the new one during a manual update, carrying typed state
across a revision bump **and a server restart**. Covers all four snapshot flavours. Mirrors the Rust test
`hot_update.rs:agent_can_be_invoked_after_manual_snapshot_update_and_restart`. Prints `FAIL: …` and exits 1 on a mismatch.

### `native-contract-tests.sh <workdir>` and `contract-tests/`

Scaffolds an app, swaps in `contract-tests/ContractProbeAgent.kt` (about 1,000 lines), builds and deploys it, then
invokes one probe per capability on **its own durable agent**, so a trap in one probe cannot fail later probes. Exits 0
only when every probe passed; a failing probe does not abort the run.

It is **contract-only**: a probe proves a host call crossed the compiled-Kotlin ⇄ host boundary and returned the
expected shape without trapping. It does not prove functional correctness, and it does not cover durability replay.
`contract-tests/README.md` lists the capabilities, the Kotlin argument dialect the probes use, and the three probes that
are negative-path by necessity. A probe passes only if the result contains the quoted `"OK`; a bare `OK` also matches the
CLI's progress output and once gave a false PASS.

| File | Role |
|---|---|
| `ContractProbeAgent.kt` | The probe agent. One method per capability. |
| `CounterAgentSnapshot.kt.fixture` | A snapshot-enabled `CounterAgent`. Used by `native-snapshot-e2e.sh`. The `.fixture` suffix keeps Gradle from compiling it in place. |
| `durable-stream-peer.py` | A minimal external durable-stream peer. The executor performs the HTTP itself, so this stands in for the far end. |
| `http-echo-peer.py` | A minimal HTTP echo server for the outgoing-HTTP probes (`POST /echo`). |

### `bridge/`

Runs the generated Kotlin **bridges** on a real executor. `run.sh` deploys `app/`, invokes it, and compares each result:

- `app/provider` is a Kotlin `Calculator` agent plus a secured agent. `app/consumer` is a Kotlin component that calls the
  `Calculator` and Rust tools through the guest clients `golem build` generates from its dependencies
  (`BridgeCaller.kt`, `ToolBridgeCaller.kt`).
- `external/` is a plain JVM program (`ExternalMain.kt`) that calls the deployed `Calculator` through the external REST
  client `golem-cli generate-bridge` writes.

Needs the artifacts that `tool-typed-middleware/build.sh` publishes. Exits non-zero on any mismatch.

### `real-sdk-compile/`

Compiles the code the KSP processor generates against the real SDK. No server, `golem` or `wasm-tools` is needed. The
unit tests of `ksp/` compile generated source only against a JVM stub of `cloud.golem.runtime`, so a renamed SDK class
would pass them. This build runs the processor over the acceptance fixtures of class C for Kotlin/Wasm, with the SDK
and the processor resolved from mavenLocal.

```bash
for m in sdk ksp; do (cd sdks/kotlin/$m && ./gradlew --no-daemon -PgolemSdkVersion=0.0.0-SNAPSHOT publishToMavenLocal); done
cd sdks/kotlin/scripts/real-sdk-compile && ./gradlew --no-daemon --continue compileKotlinWasmWasi
```

Publish again after every change to `sdk/` or `ksp/`. The build compiles whatever is in mavenLocal. The fixtures are
read in place and not copied. The processor needs the agents of one module to share one package, and writes one WIT file per
agent class name, so each fixture directory (or file, where a directory mixes packages) is a module of its own. The
example's `CounterAgent` is left out because it shares its WIT name with the snapshot fixture. CI runs it in
`build-golem-kotlin`. It proves that the generated source compiles. It does not run it.

### `real-plugin-build/`

Applies the real `cloud.golem.wasm-component` plugin to a real Kotlin/Wasm and KSP project and runs the whole
`nativeComponent` chain with the real `wasm-tools`. No server or `golem` is needed. The unit tests of `gradle-plugin/`
use a `FakeKspExtension` and `ProjectBuilder`, and never run the Kotlin/Wasm compile or `wasm-tools`. So a renamed
Kotlin Gradle plugin task or output directory, a changed `ksp { arg(...) }` signature, or a `wasm-tools` flag that no longer
exists would pass them.

```bash
for m in sdk ksp gradle-plugin; do (cd sdks/kotlin/$m && ./gradlew --no-daemon -PgolemSdkVersion=0.0.0-SNAPSHOT publishToMavenLocal); done
cd sdks/kotlin/scripts/real-plugin-build && ./gradlew --no-daemon verifyComponent verifyAdapterOverride
```

`verifyComponent` checks that the component exports `golem:agent/guest` (`wasm-tools component wit`) and that
`wasmComponent.arenaHeadroomKiB` reached the processor, which shows as `configureArenaHeadroom(<bytes>)` in the generated
source. The agent is the example's, read in place. `witNativeDir` is left unset, so the plugin extracts its bundled
`wit-native.zip`.

`verifyAdapterOverride` checks `wasmComponent.wasiAdapterPath`. It runs three more `nativeComponent` tasks over the same
core module. With a valid adapter at a path of its own (a copy of the cached one, found under
`$GRADLE_USER_HOME/caches/golem/wasi-adapter`), the component is byte-for-byte the default one. With a file that is not an
adapter, `wasm-tools` must fail, which a download would not. With a path that does not exist, the task must refuse it by name.
The unit tests call `WasiAdapter.resolve` directly, so they do not notice a task that stops passing the property on.

Needs Java 17 or newer on `PATH`, `wasm-tools` on `PATH`, and network access on the first run for the
WASI adapter. Publish again after every change to `sdk/`, `ksp/` or `gradle-plugin/`. CI runs it in `build-golem-kotlin`.

### `tool-typed-middleware/`

Fixtures for `@ToolDefinition` interfaces and the typed middleware generated from them. Its own `README.md` has the detail.

| Entry | Needs a server? | What it checks |
|---|---|---|
| `build.sh` | no | Republishes the SDK, KSP and plugin at the snapshot version, publishes `library/`, builds `component/` and `single-module/` with `nativeComponent`, runs `wasm-tools validate`, and checks each exports `golem:tool/tool-middleware-guest`. Compile-time proof of the generated shapes. |
| `executor/run.sh` | yes | Deploys a Rust leaf provider (`executor/probe-provider`, a small Cargo project of its own) and a Kotlin component (`executor/app`) with a transparent middleware, an adapter and two caller agents; calls through both chains and compares results. Also covers `@Arg` options, flags, command groups, overlapped calls with `cancel()`, stdin/stdout streaming through a middleware, tool reflection and a webhook. |
| `library/`, `component/`, `single-module/` | – | The three Gradle fixtures `build.sh` builds. |

Not covered: crash replay of an outstanding wrapped call, and request-time auth enforcement. Needs the Rust toolchain
and WASI SDK for the provider.

---

## C. Acceptance fixtures (source only)

One or two Kotlin files per directory, each an agent set written to exercise one feature on a real executor. **No script in
this tree runs them on an executor**, though `real-sdk-compile/` compiles them. Each was dropped into a scaffolded app by hand (replace or add a file under
`src/wasmWasiMain/kotlin/` of an app made as in `native-e2e.sh`), built, deployed and invoked.

They matter because `sdks/kotlin/docs/api/*.md` cites them as the evidence behind "verified on a real 1.6.0 executor".
**Moving or deleting a directory leaves those links dangling**, so decide their home together with `docs/api`.

| Directory | File(s) | Feature exercised | Cited by `docs/api/` |
|---|---|---|---|
| `config-agents/` | `ConfigAgents.kt` | Agent config: nested paths, secrets, optional keys, RPC overrides | `config.md` |
| `durable-streams/` | `DurableStreamAgents.kt` | Durable streams: JSON/bytes read, JSON/bytes writers, a bearer secret, and a `410 Gone` bogus-checkpoint read (takes the stream URL as an argument; `contract-tests/durable-stream-peer.py` is a peer for it) | `durable-streams.md` |
| `http-bindings/` | `HttpBindingAgents.kt` | `@Endpoint` bindings: path and query variables, `@Header`, PATCH | `http-routers.md` |
| `http-routers/` | `RouterAgents.kt`, `RouterHandlerAgents.kt` | `@HttpRouter` agents and custom `@HttpHandler` | `http-routers.md` |
| `permission-cards/` | `PermissionCardAgents.kt` | Permission cards; same agent types and methods as the Scala acceptance fixture | `permissions.md` |
| `reflection/` | `ReflectionAgents.kt` | Agent reflection: a `Counter` agent and a `Reflector` agent that describes and calls it | – |
| `schema-corners/` | `SchemaCornersAgents.kt`, `RestrictedAgents.kt` | 1.6.0 schema corners (`Uuid`, `Duration`, bytes, unstructured text) and allow-listed unstructured types (`@Languages`, `@MimeTypes`) behind a `@RemoteAgent` | – |
| `snapshots/` | `SnapshotAgents.kt` | Custom-byte and multipart snapshot agents (`snapshotting = "enabled"`) | – |
| `tool-middleware/` | `ToolMiddlewares.kt` | `@ToolMiddleware` classes: pass-through, upper-case stdout, deny, and a prefix middleware with typed installation parameters | `tool-middleware.md` |
| `tool-reflection/` | `ToolInspector.kt` | Tool reflection (`ToolInfo`, commands, arguments) against Rust provider components | `reflection.md` |
| `websocket/` | `WebSocketAgents.kt` | WebSocket client against an echo server | `websocket.md` |

The Python peers in `contract-tests/` are the far end for the durable-stream agents and for the outgoing-HTTP probes
in `ContractProbeAgent`.

---

## D. Diagnostics

### `check-imports.py`

Lists the core-module imports of a compiled Kotlin/Wasm agent that the `kotlin-agent` world does not provide (a missing
interface or a missing function). It checks existence only: a changed *signature* still looks present, and
`wasm-tools component new` is what validates signatures. It also checks the async intrinsics (`[async-lower]…`,
stream/future builtins).

```sh
scripts/check-imports.py <core.wasm>   # default: the example's counter-agent.wasm
scripts/check-imports.py --sources     # every @WasmImport under sdk/src, not only those an agent reaches
```

Use it after a WIT sync or a Kotlin/Wasm compiler bump, when a build fails with an unresolved import.

---

## Not here

- **GC soak and regression harness** (long-running stress, RSS plateau checks, k6, a docker stack): kept on the
  `wasmgc-soak` branch only.
- **Build output.** `build/`, `.gradle/`, `.kotlin/`, `golem-temp/` and `executor/probe-provider/target/` are git-ignored
  by the `.gitignore` files in `bridge/` and `tool-typed-middleware/`.
