#!/usr/bin/env python3
"""
OLS regression: does GC workload (churn) and concurrency (VUs) predict
behavioral failure and latency?

Reads a cells CSV produced by gc-regression.sh:

  cell_id,churn,vus,rate,agents,duration_s,http_reqs,fail_rate,check_pass_rate,
  latency_avg_ms,latency_p50_ms,latency_p90_ms,latency_p95_ms,latency_max_ms,
  dropped_iterations,completed_rate

Fits ordinary least squares (pure stdlib):

  Y ~ 1 + z(churn) + z(vus) + z(churn)*z(vus)

for Y in { fail_rate, latency_p95_ms, latency_avg_ms }.

Prints coefficients, R², adjusted R², residual SE, coefficient t-stats,
and a short interpretation of whether churn (GC work) drives failures.

Usage:
  gc-regression-analyze.py <cells.csv> [--report <out.md>]
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path
from typing import List, Sequence, Tuple


def read_cells(path: Path) -> List[dict]:
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        raise SystemExit(f"no data rows in {path}")
    return rows


def fget(row: dict, key: str) -> float:
    return float(row[key])


def mean(xs: Sequence[float]) -> float:
    return sum(xs) / len(xs)


def stdev(xs: Sequence[float]) -> float:
    m = mean(xs)
    if len(xs) < 2:
        return 0.0
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def zscore(xs: Sequence[float]) -> List[float]:
    s = stdev(xs)
    m = mean(xs)
    if s < 1e-12:
        return [0.0] * len(xs)
    return [(x - m) / s for x in xs]


def mat_transpose(A: List[List[float]]) -> List[List[float]]:
    return [list(row) for row in zip(*A)]


def mat_mul(A: List[List[float]], B: List[List[float]]) -> List[List[float]]:
    bt = mat_transpose(B)
    out: List[List[float]] = []
    for row in A:
        out.append([sum(a * b for a, b in zip(row, col)) for col in bt])
    return out


def mat_vec(A: List[List[float]], v: Sequence[float]) -> List[float]:
    return [sum(a * x for a, x in zip(row, v)) for row in A]


def identity(n: int) -> List[List[float]]:
    return [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]


def gauss_jordan_invert(M: List[List[float]]) -> List[List[float]]:
    """Invert square matrix via Gauss–Jordan; raises on singular."""
    n = len(M)
    A = [row[:] + ident for row, ident in zip(M, identity(n))]
    for col in range(n):
        pivot = col
        for r in range(col + 1, n):
            if abs(A[r][col]) > abs(A[pivot][col]):
                pivot = r
        if abs(A[pivot][col]) < 1e-14:
            raise ValueError("singular design matrix (need more variance in factors)")
        A[col], A[pivot] = A[pivot], A[col]
        div = A[col][col]
        A[col] = [x / div for x in A[col]]
        for r in range(n):
            if r == col:
                continue
            factor = A[r][col]
            A[r] = [a - factor * b for a, b in zip(A[r], A[col])]
    return [row[n:] for row in A]


def ols(
    y: Sequence[float], X: List[List[float]], names: Sequence[str]
) -> dict:
    """
    y: length n
    X: n x p design matrix (include intercept column)
    """
    n = len(y)
    n_params = len(X[0])
    if n <= n_params:
        raise ValueError(f"need n > p observations (got n={n}, p={n_params})")

    # Zero-variance outcome (e.g. all fail_rate=0): report degenerate fit explicitly
    y_m = mean(y)
    ss_tot = sum((yi - y_m) ** 2 for yi in y)
    if ss_tot < 1e-18:
        return {
            "names": list(names),
            "beta": [y_m] + [0.0] * (n_params - 1),
            "se": [0.0] * n_params,
            "t": [0.0] * n_params,
            "p": [1.0] * n_params,
            "r2": 0.0,
            "adj_r2": 0.0,
            "n": n,
            "p_params": n_params,
            "mse": 0.0,
            "rmse": 0.0,
            "yhat": list(y),
            "resid": [0.0] * n,
            "degenerate": "outcome has zero variance (all cells identical)",
        }

    Xt = mat_transpose(X)
    XtX = mat_mul(Xt, X)
    XtX_inv = gauss_jordan_invert(XtX)
    Xty = mat_vec(Xt, y)
    beta = mat_vec(XtX_inv, Xty)

    yhat = mat_vec(X, beta)
    resid = [yi - yh for yi, yh in zip(y, yhat)]
    ss_res = sum(r * r for r in resid)
    r2 = 1.0 - ss_res / ss_tot
    adj_r2 = 1.0 - (1.0 - r2) * (n - 1) / (n - n_params) if n > n_params else r2
    dof = n - n_params
    mse = ss_res / dof if dof > 0 else float("nan")
    se_beta = [math.sqrt(max(0.0, mse * XtX_inv[i][i])) for i in range(n_params)]
    t_stats = [
        (b / s if s > 1e-18 else float("inf")) for b, s in zip(beta, se_beta)
    ]
    p_vals = []
    for t in t_stats:
        pv = math.erfc(abs(t) / math.sqrt(2.0))
        p_vals.append(min(1.0, pv))

    return {
        "names": list(names),
        "beta": beta,
        "se": se_beta,
        "t": t_stats,
        "p": p_vals,
        "r2": r2,
        "adj_r2": adj_r2,
        "n": n,
        "p_params": n_params,
        "mse": mse,
        "rmse": math.sqrt(mse) if mse == mse else float("nan"),
        "yhat": yhat,
        "resid": resid,
    }


def fit_models(rows: List[dict]) -> dict:
    churn = [fget(r, "churn") for r in rows]
    vus = [fget(r, "vus") for r in rows]
    zc = zscore(churn)
    zv = zscore(vus)
    interact = [a * b for a, b in zip(zc, zv)]

    # design: intercept, z_churn, z_vus, interaction
    X = [[1.0, a, b, c] for a, b, c in zip(zc, zv, interact)]
    names = ["intercept", "z_churn", "z_vus", "z_churn:z_vus"]

    outcomes = {}
    for yname in ("fail_rate", "latency_p95_ms", "latency_avg_ms"):
        y = [fget(r, yname) for r in rows]
        try:
            outcomes[yname] = ols(y, X, names)
        except ValueError as e:
            outcomes[yname] = {"error": str(e)}

    # also simple bivariate: fail_rate ~ churn only (unscaled for slope interpretability)
    # fail_rate = b0 + b1 * (churn/1000)
    X_c = [[1.0, c / 1000.0] for c in churn]
    try:
        outcomes["fail_rate_vs_churn_k"] = ols(
            [fget(r, "fail_rate") for r in rows],
            X_c,
            ["intercept", "churn_thousands"],
        )
    except ValueError as e:
        outcomes["fail_rate_vs_churn_k"] = {"error": str(e)}

    X_l = [[1.0, c / 1000.0] for c in churn]
    try:
        outcomes["p95_vs_churn_k"] = ols(
            [fget(r, "latency_p95_ms") for r in rows],
            X_l,
            ["intercept", "churn_thousands"],
        )
    except ValueError as e:
        outcomes["p95_vs_churn_k"] = {"error": str(e)}

    return {
        "n_cells": len(rows),
        "churn_mean": mean(churn),
        "churn_sd": stdev(churn),
        "vus_mean": mean(vus),
        "vus_sd": stdev(vus),
        "models": outcomes,
        "rows": rows,
    }


def fmt_model(name: str, m: dict) -> str:
    if "error" in m:
        return f"### {name}\n\n_Could not fit: {m['error']}_\n"
    lines = [
        f"### {name}",
        "",
        f"- n = {m['n']}, parameters = {m['p_params']}",
        f"- R² = {m['r2']:.4f}, adj R² = {m['adj_r2']:.4f}, RMSE = {m['rmse']:.6g}",
    ]
    if m.get("degenerate"):
        lines.append(f"- **degenerate fit:** {m['degenerate']}")
    lines += [
        "",
        "| term | coef | SE | t | p (normal approx) |",
        "|---|---:|---:|---:|---:|",
    ]
    for nm, b, se, t, p in zip(m["names"], m["beta"], m["se"], m["t"], m["p"]):
        stars = ""
        if p < 0.001:
            stars = " ***"
        elif p < 0.01:
            stars = " **"
        elif p < 0.05:
            stars = " *"
        lines.append(f"| `{nm}` | {b:.6g} | {se:.6g} | {t:.3f} | {p:.4g}{stars} |")
    lines.append("")
    lines.append("\\* p&lt;0.05, \\*\\* p&lt;0.01, \\*\\*\\* p&lt;0.001 (normal approx; not exact t-dist).")
    lines.append("")
    return "\n".join(lines)


def interpret(result: dict) -> str:
    models = result["models"]
    lines = ["## Interpretation", ""]

    fr = models.get("fail_rate", {})
    p95 = models.get("latency_p95_ms", {})
    fr_c = models.get("fail_rate_vs_churn_k", {})
    p95_c = models.get("p95_vs_churn_k", {})

    def coef(m: dict, term: str):
        if "error" in m or "names" not in m:
            return None
        try:
            i = m["names"].index(term)
        except ValueError:
            return None
        return m["beta"][i], m["p"][i]

    # Zero failures across matrix
    if fr.get("degenerate") or (
        "beta" in fr and all(abs(b) < 1e-15 for b in fr.get("beta", [1]))
    ):
        lines.append(
            "- **fail_rate was 0.0 in every cell** (within REQ_TIMEOUT). "
            "GC workload did **not** produce behavioral failures in this matrix; "
            "look at latency models for GC cost, and use a shorter REQ_TIMEOUT / higher "
            "churn×VUs (or longer soak) to surface timeout failures."
        )

    # Churn → latency
    c = coef(p95, "z_churn")
    if c and not p95.get("degenerate"):
        b, p = c
        if p < 0.05 and b > 0:
            lines.append(
                f"- **GC workload (churn) increases p95 latency** "
                f"(standardized coef={b:.3f}, p≈{p:.3g}). "
                "Heavier per-call allocation/GC work slows responses."
            )
        elif p < 0.05 and b < 0:
            lines.append(
                f"- Unexpected: higher churn associated with *lower* p95 (coef={b:.3f}, p≈{p:.3g}). "
                "Check matrix design / dropped iterations."
            )
        else:
            lines.append(
                f"- No clear churn→p95 effect in this sample (z_churn coef={b:.3f}, p≈{p:.3g})."
            )

    # Churn → fail rate
    c = coef(fr, "z_churn")
    if c and not fr.get("degenerate"):
        b, p = c
        if p < 0.05 and b > 0:
            lines.append(
                f"- **GC workload predicts response failures** "
                f"(fail_rate z_churn coef={b:.3f}, p≈{p:.3g}). "
                "Failures rise as allocation/GC work increases — consistent with timeouts "
                "when GC+alloc cost pushes latency past the client budget."
            )
        elif p >= 0.05:
            lines.append(
                f"- Churn alone is **not a significant predictor of fail_rate** in the multi-factor model "
                f"(coef={b:.3f}, p≈{p:.3g}). Failures may be driven more by concurrency or noise."
            )
        else:
            lines.append(
                f"- z_churn→fail_rate coef={b:.3f}, p≈{p:.3g}."
            )

    # VUs
    c = coef(fr, "z_vus")
    if c:
        b, p = c
        if p < 0.05 and b > 0:
            lines.append(
                f"- **Concurrency (VUs) predicts failures** (coef={b:.3f}, p≈{p:.3g}): "
                "contention/queueing on the executor contributes independently of churn size."
            )
        elif p < 0.05:
            lines.append(f"- z_vus→fail_rate coef={b:.3f}, p≈{p:.3g}.")
        else:
            lines.append(
                f"- Concurrency effect on fail_rate not significant here (coef={b:.3f}, p≈{p:.3g})."
            )

    # Interaction
    c = coef(fr, "z_churn:z_vus")
    if c:
        b, p = c
        if p < 0.05 and b > 0:
            lines.append(
                f"- **Positive churn×VUs interaction** (coef={b:.3f}, p≈{p:.3g}): "
                "GC-heavy calls hurt *more* under high concurrency (overload amplification)."
            )
        elif p < 0.05 and b < 0:
            lines.append(
                f"- Negative interaction (coef={b:.3f}, p≈{p:.3g}): unusual — inspect raw cells."
            )
        else:
            lines.append(
                f"- No significant churn×VUs interaction on fail_rate (coef={b:.3f}, p≈{p:.3g})."
            )

    # Raw slope: fail per 1000 objects
    if "error" not in fr_c and "beta" in fr_c:
        b1 = fr_c["beta"][1]
        p1 = fr_c["p"][1]
        lines.append(
            f"- Bivariate slope: **Δfail_rate ≈ {b1:.4g} per 1000 churn objects** "
            f"(p≈{p1:.3g}, R²={fr_c['r2']:.3f})."
        )
    if "error" not in p95_c and "beta" in p95_c:
        b1 = p95_c["beta"][1]
        p1 = p95_c["p"][1]
        lines.append(
            f"- Bivariate slope: **Δp95 ≈ {b1:.4g} ms per 1000 churn objects** "
            f"(p≈{p1:.3g}, R²={p95_c['r2']:.3f})."
        )

    lines.append("")
    lines.append(
        "**How to read for the soak question:** if churn significantly predicts "
        "`fail_rate` and/or `latency_p95` (especially with a positive interaction with VUs), "
        "then GC/allocation workload is a cause of behavioral failure under load — even when "
        "RSS still plateaus (GC reclaim works, but cost causes timeouts). If only VUs predicts "
        "failures while churn does not, concurrency/scheduling dominates over GC work size."
    )
    lines.append("")
    return "\n".join(lines)


def cell_table(rows: List[dict]) -> str:
    headers = [
        "churn",
        "vus",
        "http_reqs",
        "fail_rate",
        "latency_avg_ms",
        "latency_p95_ms",
        "dropped_iterations",
        "completed_rate",
    ]
    lines = [
        "## Cell results",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---:" for _ in headers]) + " |",
    ]
    for r in rows:
        lines.append(
            "| "
            + " | ".join(
                f"{fget(r, h):.6g}" if h != "http_reqs" else str(int(fget(r, h)))
                for h in headers
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def render_report(result: dict) -> str:
    parts = [
        "# GC workload regression report",
        "",
        "Factorial matrix of **churn** (per-call WasmGC allocations) × **VUs** (concurrency).",
        "OLS on standardized predictors plus bivariate slopes on raw churn.",
        "",
        f"- cells: **{result['n_cells']}**",
        f"- churn mean±sd: {result['churn_mean']:.0f} ± {result['churn_sd']:.0f}",
        f"- VUs mean±sd: {result['vus_mean']:.0f} ± {result['vus_sd']:.0f}",
        "",
        cell_table(result["rows"]),
        "## Multi-factor models",
        "",
        "Predictors are **z-scored** within the matrix so coefficients are comparable.",
        "Model: `Y ~ 1 + z_churn + z_vus + z_churn:z_vus`.",
        "",
    ]
    for name in ("fail_rate", "latency_p95_ms", "latency_avg_ms"):
        parts.append(fmt_model(name, result["models"][name]))
    parts.append("## Bivariate (churn only)")
    parts.append("")
    parts.append(fmt_model("fail_rate ~ churn_thousands", result["models"]["fail_rate_vs_churn_k"]))
    parts.append(fmt_model("latency_p95_ms ~ churn_thousands", result["models"]["p95_vs_churn_k"]))
    parts.append(interpret(result))
    return "\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cells_csv", type=Path)
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument("--design", type=Path, default=None, help="optional design.json from gc-regression.sh")
    args = ap.parse_args()

    rows = read_cells(args.cells_csv)
    # Drop placeholder rows with zero requests and zero latency (failed cells)
    usable = [
        r
        for r in rows
        if fget(r, "http_reqs") > 0 or fget(r, "latency_p95_ms") > 0 or fget(r, "fail_rate") < 1.0
    ]
    # Prefer rows that actually ran: http_reqs > 0
    ran = [r for r in rows if fget(r, "http_reqs") > 0]
    if len(ran) >= 4:
        rows = ran
    elif usable:
        rows = usable

    result = fit_models(rows)
    report = render_report(result)
    if args.design and args.design.is_file():
        design_txt = args.design.read_text().strip()
        report = (
            "## Experimental design\n\n```json\n"
            + design_txt
            + "\n```\n\n"
            + report
        )
    out = args.report or args.cells_csv.with_name("regression-report.md")
    out.write_text(report)
    print(report)
    print(f"\nWrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
