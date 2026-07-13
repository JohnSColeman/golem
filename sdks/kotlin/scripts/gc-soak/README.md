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
- For `SERVER_MODE=redis` (default): Docker **Postgres + Redis** plus host debug service binaries.
  Storage matches the [proven agent-example compose](https://github.com/JohnSColeman/golem-agent-example/blob/infra/infra/docker/docker-compose.yaml) — **not SQLite**:
  - registry + shard-manager → **Postgres**
  - worker-executor key-value + indexed → **Redis** (`KVStoreRedis`)
  - gateway sessions → **Redis**
  - shared filesystem blob root for component wasm
- For full container stack: **local images built from this repo**, not published
  `golemservices/*` (latest stable **v1.5.1**) — see [Docker images](#docker-images-local-branch--wasmgc).

## Modes

| Knob | Meaning | smoke default | soak default |
|---|---|---|---|
| `MODE` | `smoke` \| `soak` | `smoke` | — |
| `AGENTS` | number of distinct `{id}` instances | 50 | 2000 |
| `DURATION` | k6 soak duration | `60s` | `30m` |
| `RATE` | target requests/sec | 20 | 20 |
| `VUS` | preallocated k6 virtual users | 32 | 64 |
| `CHURN_OBJECTS` | transient objects allocated per call | 20000 | 60000 |
| `RSS_SAMPLE_SEC` | RSS sampling interval | 2 | 2 |
| `RSS_PLATEAU_TOL` | fractional tolerance for the plateau check | 0.15 | 0.15 |

Any knob may be overridden explicitly; `MODE` only sets the defaults.

## How to run

```bash
# quick smoke (CI-capable) — default SERVER_MODE=redis (Postgres+Redis stack)
MODE=smoke ./gc-soak.sh /tmp/gcsoak

# deep soak (manual; thousands of agents, 30 min)
MODE=soak ./gc-soak.sh /tmp/gcsoak

# custom (e.g. multi-hour; raise RATE only if host executor keeps up)
MODE=soak DURATION=4h AGENTS=5000 RATE=50 ./gc-soak.sh /tmp/gcsoak

# small smoke only: monolithic golem server run (MultiSqlite — not for large AGENTS)
MODE=smoke SERVER_MODE=builtin ./gc-soak.sh /tmp/gcsoak
```

### Docker stack (proven layout, local WasmGC images)

Compose layout mirrors
[golem-agent-example/infra/docker/docker-compose.yaml](https://github.com/JohnSColeman/golem-agent-example/blob/infra/infra/docker/docker-compose.yaml)
(router, redis, postgres, registry, shard-manager, worker-service, compilation, executor,
debugging). Latest stable published images are `golemservices/*:v1.5.1` and **do not** include this
branch’s WasmGC engine flags. Build local images instead:

```bash
# 1) Cross-compile Linux release bins + docker build (context = repo root)
./docker/build-images.sh

# 2) Full stack (tag default: wasmgc)
cd docker
GOLEM_REPO_ROOT="$(git rev-parse --show-toplevel)" \
  docker compose up -d

# Infra only (what SERVER_MODE=redis hybrid uses):
docker compose up -d redis postgres
```

Notes vs the proven file:

| Proven compose | This branch’s compose |
|---|---|
| `golemservices/*:${GOLEM_IMAGES_VERSION}` | local `golem-*:wasmgc` from in-tree Dockerfiles |
| `GOLEM__PERSISTENCE__TYPE=Redis` (shard-manager) | `GOLEM__DB__TYPE=Postgres` (Redis persistence removed) |
| `GOLEM__SHARD_MANAGER_SERVICE__*` / `ROUTING_TABLE__HOST` | current `GOLEM__SHARD_MANAGER__HOST/PORT` |
| registry without blob volume | registry also mounts `blob_storage` (shared component_store) |

The Dockerfiles `COPY` prebuilt binaries from `target/<triple>/release/…`. On macOS,
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
| `logs/*.log` | multi-service host stack logs (registry, executor, …) |

## GC workload regression (churn × concurrency)

When soak gate 1 fails on timeouts but RSS plateaus, the open question is whether
**GC/allocation work** (per-call object count) drives failures, or only **concurrency**.

`gc-regression.sh` runs a factorial matrix and `gc-regression-analyze.py` fits OLS:

```text
fail_rate, latency_p95  ~  1 + z(churn) + z(vus) + z(churn)×z(vus)
```

plus bivariate slopes per 1000 churn objects.

```bash
# default matrix: CHURN ∈ {1k,10k,40k} × VUS ∈ {1,8,32}, 60s cells
./gc-regression.sh /tmp/gc-regression

# denser / longer
CHURNS="500 2000 10000 40000" VUS_LIST="1 4 16 32" DURATION=90s \
  ./gc-regression.sh /tmp/gc-regression

# long soak regression: 4h per cell (3×3 = ~36h wall + deploy)
# RSS sampling on; progressive OLS after each cell; resume-safe
DURATION=4h REQ_TIMEOUT=120s SETTLE_SEC=30 RSS=1 \
  ./gc-regression.sh /tmp/gc-regression-4h

# resume after interrupt (skip finished cells; restart stack if needed)
RESUME=1 ./gc-regression.sh /tmp/gc-regression-4h
# if stack still up:
RESUME=1 SKIP_DEPLOY=1 ./gc-regression.sh /tmp/gc-regression-4h

# analyzer unit tests (synthetic data, no server)
./gc-regression-analyze.test.sh
```

Artifacts: `<workdir>/cells.csv`, `<workdir>/REGRESSION-REPORT.md`, `design.json`,
per-cell `k6-summary.json` (+ `rss.csv` when `RSS=1`).

The agent exposes `POST /gcstress/{id}/churn/{n}` so churn varies **without rebuild**.
Smoke/soak use the same path with fixed `CHURN_OBJECTS` as `n`.

## Files

| File | Role |
|---|---|
| `gc-soak.sh` | two-tier driver (scaffold → build → serve → deploy → sample → k6 → gate) |
| `start-redis-stack.sh` | Postgres+Redis multi-service stack (host bins + Docker infra) |
| `GcStressAgent.kt.fixture` | allocation-churn stress agent (`/churn` + `/churn/{n}`) |
| `gc-soak.k6.js` | k6 `constant-arrival-rate` load script |
| `gc-regression.sh` | factorial matrix driver (churn × VUs) |
| `gc-regression-analyze.py` | OLS regression + markdown report |
| `gc-regression-analyze.test.sh` | unit tests for the analyzer (synthetic CSV) |
| `rss-plateau-check.sh` | RSS plateau analyzer (exit 0 plateau / 1 climbing / 2 insufficient) |
| `rss-plateau-check.test.sh` | unit tests for the analyzer (synthetic CSVs; no server) |
| `docker/docker-compose.yaml` | proven topology + **local** WasmGC images |
| `docker/nginx.conf.template` | router template (from agent-example) |
| `docker/.env` | ports / tokens aligned with agent-example |
| `docker/build-images.sh` | cross-compile release bins + `docker build` from this branch |
| `SOAK-REPORT.md` | recorded smoke/soak results |

```bash
./rss-plateau-check.test.sh          # plateau analyzer
./gc-regression-analyze.test.sh      # regression analyzer
```
