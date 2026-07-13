#!/usr/bin/env bash
# Decide whether an RSS time-series plateaued (GC reclaiming) or is still climbing (leak / no GC).
# Usage: rss-plateau-check.sh <csv> [tolerance]   CSV rows: epoch,rss_kb (header row tolerated)
# Exit: 0 plateau, 1 climbing, 2 insufficient/bad input.
set -uo pipefail
CSV="${1:?csv path}"
TOL="${2:-0.15}"
[ -s "$CSV" ] || { echo "INSUFFICIENT no data: $CSV"; exit 2; }

awk -F, -v tol="$TOL" '
  $2 ~ /^[0-9]+$/ { v[++n] = $2 + 0 }   # keep only rows whose 2nd field is an integer (skips header)
  END {
    if (n < 8) { printf "INSUFFICIENT samples=%d (need >=8)\n", n; exit 2 }
    q = int(n / 4)
    # Q3 = (2q, 3q], Q4 = (3q, n]
    s3 = 0; for (i = 2*q + 1; i <= 3*q; i++) s3 += v[i]; m3 = s3 / q
    s4 = 0; maxq4 = 0; for (i = 3*q + 1; i <= n; i++) { s4 += v[i]; if (v[i] > maxq4) maxq4 = v[i] }
    c4 = n - 3*q; m4 = s4 / c4
    maxall = 0; for (i = 1; i <= n; i++) if (v[i] > maxall) maxall = v[i]
    if (m3 <= 0 || maxall <= 0) {
      printf "INSUFFICIENT samples=%d m3=%d maxall=%d (zero RSS — sampler failure?)\n", n, m3, maxall
      exit 2
    }
    growth = (m4 - m3) / m3                 # one-sided: a drop is fine, growth beyond tol is not
    spike  = maxq4 / maxall                 # final-window peak vs overall peak
    if (growth <= tol && spike <= 1 + tol) {
      printf "PLATEAU ok n=%d m3=%d m4=%d growth=%.3f spike=%.3f tol=%.2f\n", n, m3, m4, growth, spike, tol
      exit 0
    } else {
      printf "CLIMBING n=%d m3=%d m4=%d growth=%.3f spike=%.3f tol=%.2f\n", n, m3, m4, growth, spike, tol
      exit 1
    }
  }
' "$CSV"
