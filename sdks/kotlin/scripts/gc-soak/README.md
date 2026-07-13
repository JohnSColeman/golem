# WasmGC soak / stress test

Self-contained soak/stress harness that exercises the WasmGC garbage collector of a natively
compiled Kotlin/Wasm Golem agent. Drives intense allocation churn across many agent instances and
gates on (1) behavioral survival (zero failed invokes) and (2) host process RSS plateau (evidence
that GC is reclaiming memory).

This directory is a **sibling of `contract-tests/`**, not part of it. Contract tests probe SDK
capability boundaries; this exercises the WasmGC collector — a separate concern. It reuses the same
scaffold → build → server → deploy shape as `native-e2e.sh` / `native-snapshot-e2e.sh` but shares
no files with them.

## Prerequisites

- `golem` / `golem-cli` built from branch `kotlin-sdk-native` (wasmtime engine flags `wasm_gc`,
  `wasm_function_references`, `wasm_exceptions` present). Override paths with `GOLEM_BIN` /
  `GOLEM_CLI_BIN`.
- SDK / KSP / gradle-plugin published to `mavenLocal`.
- `k6` on PATH (`brew install k6`).
- On a machine whose default `java` is &lt; 17, point `JAVA_HOME` at a 17+ JDK for the gradle build.
- For `SERVER_MODE=redis` (default): Docker **Postgres + Redis** (compose infra) plus host debug
  service binaries. Storage matches the agent-example compose — **not SQLite**:
  - registry → **Postgres**
  - worker-executor key-value + indexed → **Redis** (`KVStoreRedis`)
  - gateway sessions → **Redis**
- For full container stack (`docker/ --profile full`): **local images built from this repo**, not
  published `golemservices/*` (latest stable **v1.5.1**) — see [Docker images](#docker-images-local-branch--wasmgc).

## Modes

| Knob | Meaning | smoke default | soak default |
|---|---|---|---|
| `MODE` | `smoke` \| `soak` | `smoke` | — |
| `AGENTS` | number of distinct `{id}` instances | 50 | 2000 |
| `DURATION` | k6 soak duration | `60s` | `30m` |
| `RATE` | target requests/sec | 200 | 2000 |
| `VUS` | preallocated k6 virtual users | 32 | 256 |
| `CHURN_OBJECTS` | transient objects allocated per call | 20000 | 60000 |
| `RSS_SAMPLE_SEC` | RSS sampling interval | 2 | 2 |
| `RSS_PLATEAU_TOL` | fractional tolerance for the plateau check | 0.15 | 0.15 |

Any knob may be overridden explicitly; `MODE` only sets the defaults.

## How to run

```bash
# quick smoke (CI-capable) — default SERVER_MODE=redis (Redis indexed storage)
MODE=smoke ./gc-soak.sh /tmp/gcsoak

# deep soak (manual; thousands of agents, 30 min)
MODE=soak ./gc-soak.sh /tmp/gcsoak

# custom (e.g. multi-hour)
MODE=soak DURATION=4h AGENTS=5000 RATE=3000 ./gc-soak.sh /tmp/gcsoak

# small smoke only: monolithic golem server run (MultiSqlite — not for large AGENTS)
MODE=smoke SERVER_MODE=builtin ./gc-soak.sh /tmp/gcsoak
```

### Docker images (local branch / WasmGC)

Latest stable published images are `golemservices/*:v1.5.1`. Those **do not** include this branch’s
WasmGC engine flags (`wasm_gc`, `wasm_function_references`, `wasm_exceptions`). For soak, use local
images built from this repo: `docker/docker-compose.yaml` builds from the in-tree Dockerfiles under
`golem-*/docker/Dockerfile` and tags them `golem-<service>:wasmgc` (override with
`GOLEM_LOCAL_IMAGE_TAG`).

```bash
# 1) Cross-compile Linux release bins + docker build (context = repo root)
./docker/build-images.sh

# 2) Bring up full Redis/Postgres-backed stack from those local images
cd docker
GOLEM_REPO_ROOT="$(git rev-parse --show-toplevel)" \
  docker compose --profile full up -d
```

The Dockerfiles `COPY` prebuilt binaries from `target/<triple>/release/…` (same layout as
`cargo make build-release` with `PLATFORM_OVERRIDE=linux/arm64|linux/amd64`). On macOS,
`build-images.sh` runs that cross-build first unless `SKIP_CARGO_BUILD=1`.

## Pass gates

1. **Behavioral survival** — k6 exits 0 (`http_req_failed==0` and `checks==1`). Any failed request
   fails the run.
2. **Host-memory plateau** — `rss-plateau-check.sh` over `rss.csv`. Mean of the final quarter of
   samples must not grow more than `RSS_PLATEAU_TOL` beyond the previous quarter, and the final-window
   peak must not exceed the overall peak by more than the same tolerance. A drop counts as plateau
   (GC reclaimed aggressively).

Guest `GET /gcstress/0/stats` is printed as a secondary correctness signal (not a hard gate).

**Tip:** if a short smoke reports `CLIMBING` (warm-up may still be rising in a 60s window), re-run
with `DURATION=120s` to give the heap time to plateau.

## Artifacts (in `<workdir>`)

| File | Meaning |
|---|---|
| `rss.csv` | host memory time-series (`epoch,rss_kb`) — the plateau evidence |
| `k6-summary.json` | request counts, error rate, latency percentiles |
| `server.log` | worker-executor / wasmtime log (traps, OOM, etc.) |

## Files

| File | Role |
|---|---|
| `gc-soak.sh` | two-tier driver (scaffold → build → serve → deploy → sample → k6 → gate) |
| `start-redis-stack.sh` | Redis-backed multi-service stack (host bins + Docker/host Redis) |
| `GcStressAgent.kt.fixture` | allocation-churn stress agent (`CHURN_OBJECTS` sed-substituted per mode) |
| `gc-soak.k6.js` | k6 `constant-arrival-rate` load script |
| `rss-plateau-check.sh` | RSS plateau analyzer (exit 0 plateau / 1 climbing / 2 insufficient) |
| `rss-plateau-check.test.sh` | unit tests for the analyzer (synthetic CSVs; no server) |
| `docker/docker-compose.yaml` | Redis/Postgres + **local** Golem images (in-tree Dockerfiles) |
| `docker/build-images.sh` | cross-compile release bins + `docker build` from this branch |

```bash
./rss-plateau-check.test.sh   # 4 passed, 0 failed
```
