# GC workload regression — live matrix results

Generated: 2026-07-13T07:00:22Z

Host: arm64 · branch: `22b073cdf` · workdir: `/tmp/gc-regression-live`

## Verdict summary

| Question | Answer |
|---|---|
| Matrix complete? | **Yes** — 9/9 cells with k6 metrics |
| Any HTTP failures within 60s timeout? | **No** — `fail_rate=0` in all cells |
| Does GC churn raise latency? | **Yes** — p95 multi-factor R²≈0.99; `z_churn`, `z_vus`, and interaction all large and positive |
| Does GC churn cause response *failures* in this matrix? | **No (not within 60s)** — all requests finished under `REQ_TIMEOUT=60s` |
| Capacity saturation? | **Yes** — `dropped_iterations` 0 → 1715 as churn×VUs increases; completed_rate collapses at 40k×32 |
| Link to prior soak failure | Soak used **60k churn × 64 VUs × 120s timeout** for 30m; this matrix tops at 40k×32 — latency path is the same mechanism, failure only appears when p95 exceeds timeout |

## How this answers the GC vs failure question

1. **GC/alloc workload is a strong driver of latency** (not just concurrency).
2. **Concurrency amplifies** that cost (positive churn×VUs interaction on p95/avg).
3. **Behavioral failures (timeouts) are a threshold effect**: when cost pushes latency past the client budget. This 3×3 matrix stayed under 60s (max observed ~34s), so fail_rate stayed 0; the full soak crossed the budget.

---

## Experimental design

```json
{
  "design": "full_factorial",
  "factors": {
    "churn": {"levels": [1000,10000,40000], "unit": "allocations_per_invoke", "role": "GC_workload"},
    "vus": {"levels": [1,8,32], "unit": "concurrent_clients", "role": "concurrency", "note": "RATE set equal to VUs per cell"}
  },
  "cells": 9,
  "duration_per_cell": "60s",
  "duration_s": 60,
  "agents": 32,
  "req_timeout": "60s",
  "outcomes": ["fail_rate", "latency_p95_ms", "latency_avg_ms"],
  "model": "Y ~ 1 + z(churn) + z(vus) + z(churn)*z(vus)",
  "stack": "SERVER_MODE=redis (Postgres registry + Redis KV/KVStoreRedis + shared blob)"
}
```

# GC workload regression report

Factorial matrix of **churn** (per-call WasmGC allocations) × **VUs** (concurrency).
OLS on standardized predictors plus bivariate slopes on raw churn.

- cells: **9**
- churn mean±sd: 17000 ± 17685
- VUs mean±sd: 14 ± 14

## Cell results

| churn | vus | http_reqs | fail_rate | latency_avg_ms | latency_p95_ms | dropped_iterations | completed_rate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000 | 1 | 61 | 0 | 75.5144 | 94.43 | 0 | 1.01544 |
| 1000 | 8 | 480 | 0 | 51.2819 | 86.9235 | 0 | 7.99985 |
| 1000 | 32 | 1921 | 0 | 48.0415 | 79.848 | 0 | 31.9928 |
| 10000 | 1 | 60 | 0 | 406.731 | 428.916 | 0 | 0.999986 |
| 10000 | 8 | 480 | 0 | 418.534 | 535.165 | 0 | 7.96545 |
| 10000 | 32 | 745 | 0 | 2562.35 | 5337.32 | 1176 | 12.0332 |
| 40000 | 1 | 31 | 0 | 1525.74 | 1628.06 | 30 | 0.503987 |
| 40000 | 8 | 181 | 0 | 2594.81 | 4049.21 | 300 | 2.90111 |
| 40000 | 32 | 205 | 0 | 9970.49 | 19258.2 | 1715 | 2.97611 |

## Multi-factor models

Predictors are **z-scored** within the matrix so coefficients are comparable.
Model: `Y ~ 1 + z_churn + z_vus + z_churn:z_vus`.

### fail_rate

- n = 9, parameters = 4
- R² = 0.0000, adj R² = 0.0000, RMSE = 0
- **degenerate fit:** outcome has zero variance (all cells identical)

| term | coef | SE | t | p (normal approx) |
|---|---:|---:|---:|---:|
| `intercept` | 0 | 0 | 0.000 | 1 |
| `z_churn` | 0 | 0 | 0.000 | 1 |
| `z_vus` | 0 | 0 | 0.000 | 1 |
| `z_churn:z_vus` | 0 | 0 | 0.000 | 1 |

\* p&lt;0.05, \*\* p&lt;0.01, \*\*\* p&lt;0.001 (normal approx; not exact t-dist).

### latency_p95_ms

- n = 9, parameters = 4
- R² = 0.9919, adj R² = 0.9871, RMSE = 705.018

| term | coef | SE | t | p (normal approx) |
|---|---:|---:|---:|---:|
| `intercept` | 3499.79 | 235.006 | 14.892 | 3.696e-50 *** |
| `z_churn` | 3712.43 | 249.261 | 14.894 | 3.62e-50 *** |
| `z_vus` | 3539.21 | 249.261 | 14.199 | 9.32e-46 *** |
| `z_churn:z_vus` | 3668.85 | 264.382 | 13.877 | 8.722e-44 *** |

\* p&lt;0.05, \*\* p&lt;0.01, \*\*\* p&lt;0.001 (normal approx; not exact t-dist).

### latency_avg_ms

- n = 9, parameters = 4
- R² = 0.9926, adj R² = 0.9882, RMSE = 345.193

| term | coef | SE | t | p (normal approx) |
|---|---:|---:|---:|---:|
| `intercept` | 1961.5 | 115.064 | 17.047 | 3.679e-65 *** |
| `z_churn` | 2103.39 | 122.044 | 17.235 | 1.459e-66 *** |
| `z_vus` | 1667.68 | 122.044 | 13.665 | 1.653e-42 *** |
| `z_churn:z_vus` | 1779.66 | 129.447 | 13.748 | 5.226e-43 *** |

\* p&lt;0.05, \*\* p&lt;0.01, \*\*\* p&lt;0.001 (normal approx; not exact t-dist).

## Bivariate (churn only)

### fail_rate ~ churn_thousands

- n = 9, parameters = 2
- R² = 0.0000, adj R² = 0.0000, RMSE = 0
- **degenerate fit:** outcome has zero variance (all cells identical)

| term | coef | SE | t | p (normal approx) |
|---|---:|---:|---:|---:|
| `intercept` | 0 | 0 | 0.000 | 1 |
| `churn_thousands` | 0 | 0 | 0.000 | 1 |

\* p&lt;0.05, \*\* p&lt;0.01, \*\*\* p&lt;0.001 (normal approx; not exact t-dist).

### latency_p95_ms ~ churn_thousands

- n = 9, parameters = 2
- R² = 0.3572, adj R² = 0.2654, RMSE = 5323.96

| term | coef | SE | t | p (normal approx) |
|---|---:|---:|---:|---:|
| `intercept` | -68.9017 | 2534.44 | -0.027 | 0.9783 |
| `churn_thousands` | 209.923 | 106.437 | 1.972 | 0.04858 * |

\* p&lt;0.05, \*\* p&lt;0.01, \*\*\* p&lt;0.001 (normal approx; not exact t-dist).

## Interpretation

- **fail_rate was 0.0 in every cell** (within REQ_TIMEOUT). GC workload did **not** produce behavioral failures in this matrix; look at latency models for GC cost, and use a shorter REQ_TIMEOUT / higher churn×VUs (or longer soak) to surface timeout failures.
- **GC workload (churn) increases p95 latency** (standardized coef=3712.433, p≈3.62e-50). Heavier per-call allocation/GC work slows responses.
- Concurrency effect on fail_rate not significant here (coef=0.000, p≈1).
- No significant churn×VUs interaction on fail_rate (coef=0.000, p≈1).
- Bivariate slope: **Δfail_rate ≈ 0 per 1000 churn objects** (p≈1, R²=0.000).
- Bivariate slope: **Δp95 ≈ 209.9 ms per 1000 churn objects** (p≈0.0486, R²=0.357).

**How to read for the soak question:** if churn significantly predicts `fail_rate` and/or `latency_p95` (especially with a positive interaction with VUs), then GC/allocation workload is a cause of behavioral failure under load — even when RSS still plateaus (GC reclaim works, but cost causes timeouts). If only VUs predicts failures while churn does not, concurrency/scheduling dominates over GC work size.
