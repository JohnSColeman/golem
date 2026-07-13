#!/usr/bin/env bash
# Unit tests for gc-regression-analyze.py (synthetic cells; no server).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "  PASS $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    fail=$((fail + 1))
  fi
}

# Synthetic factorial: fail_rate and p95 grow with churn and vus (and product).
# churn in {1k,10k,40k}, vus in {1,8,32}
python3 - "$TMP/cells.csv" <<'PY'
import csv
path = __import__("sys").argv[1]
rows = []
for churn in (1000, 5000, 10000, 20000, 40000):
    for vus in (1, 4, 8, 16, 32):
        # Linear ground truth (no cap) so OLS recovers high R²
        fail = 0.000003 * churn + 0.004 * vus + 0.00000008 * churn * vus
        p95 = 50 + 1.2 * (churn / 1000.0) + 35 * vus + 0.05 * (churn / 1000.0) * vus
        avg = p95 * 0.6
        rows.append({
            "cell_id": f"c{len(rows)+1:02d}",
            "churn": churn,
            "vus": vus,
            "rate": vus,
            "agents": 32,
            "duration_s": 45,
            "http_reqs": 100,
            "fail_rate": fail,
            "check_pass_rate": max(0.0, 1.0 - fail),
            "latency_avg_ms": avg,
            "latency_p50_ms": avg * 0.9,
            "latency_p90_ms": p95 * 0.95,
            "latency_p95_ms": p95,
            "latency_max_ms": p95 * 1.1,
            "dropped_iterations": 0,
            "completed_rate": 2.0,
        })
fields = list(rows[0].keys())
with open(path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(f"wrote {len(rows)} synthetic cells")
PY

python3 "$SCRIPT_DIR/gc-regression-analyze.py" "$TMP/cells.csv" --report "$TMP/report.md" >"$TMP/out.txt"

check "report exists" test -s "$TMP/report.md"
check "mentions fail_rate model" grep -q "### fail_rate" "$TMP/report.md"
check "mentions interpretation" grep -q "Interpretation" "$TMP/report.md"
# Synthetic data is constructed so churn and vus both raise fail_rate → expect positive language
check "detects churn→latency or fail" \
  grep -Eqi "churn.*(latency|failure|fail_rate)|GC workload" "$TMP/report.md"
check "R2 reported" grep -q "R²" "$TMP/report.md"
# Bivariate slope on churn should be positive for fail_rate
check "positive bivariate fail slope" \
  python3 - "$TMP/cells.csv" "$SCRIPT_DIR/gc-regression-analyze.py" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("reg", sys.argv[2])
reg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reg)
rows = reg.read_cells(Path(sys.argv[1]))
r = reg.fit_models(rows)
m = r["models"]["fail_rate_vs_churn_k"]
assert "error" not in m, m
assert m["beta"][1] > 0, m["beta"]
assert m["r2"] > 0.2, m["r2"]
m2 = r["models"]["fail_rate"]
assert m2["r2"] > 0.85, ("multi R2 too low", m2["r2"])
# z_churn should be positive on synthetic data
i = m2["names"].index("z_churn")
assert m2["beta"][i] > 0, m2["beta"]
print("ok slopes", m["beta"][1], m2["beta"][i], "R2", m2["r2"])
PY

# Singular / constant-churn matrix should not crash hard on bivariate
python3 - "$TMP/const.csv" <<'PY'
import csv
path = __import__("sys").argv[1]
rows = []
for vus in (1, 8, 32, 16, 4):
    rows.append({
        "cell_id": f"c{len(rows)+1}",
        "churn": 10000, "vus": vus, "rate": vus, "agents": 8, "duration_s": 30,
        "http_reqs": 50, "fail_rate": 0.01 * vus, "check_pass_rate": 0.9,
        "latency_avg_ms": 100 * vus, "latency_p50_ms": 90 * vus,
        "latency_p90_ms": 120 * vus, "latency_p95_ms": 130 * vus, "latency_max_ms": 200 * vus,
        "dropped_iterations": 0, "completed_rate": 1.0,
    })
with open(path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader(); w.writerows(rows)
PY
python3 "$SCRIPT_DIR/gc-regression-analyze.py" "$TMP/const.csv" --report "$TMP/const-report.md" >/dev/null
check "constant-churn matrix still produces report" test -s "$TMP/const-report.md"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
