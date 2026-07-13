#!/usr/bin/env bash
# Unit tests for rss-plateau-check.sh using synthetic CSVs (no server needed).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/rss-plateau-check.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
expect() { # <name> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1 (expected exit $2, got $3)"; fail=$((fail+1)); fi
}

# Plateau: rises then flat -> exit 0
{ echo "epoch,rss_kb";
  for i in $(seq 1 20); do echo "$i,$((100000 + i*5000))"; done          # ramp
  for i in $(seq 21 40); do echo "$i,220000"; done; } > "$TMP/plateau.csv" # flat
"$CHECK" "$TMP/plateau.csv" 0.15 >/dev/null; expect "flat-tail plateau" 0 "$?"

# Climbing: monotonic rise all the way -> exit 1
{ echo "epoch,rss_kb"; for i in $(seq 1 40); do echo "$i,$((100000 + i*10000))"; done; } > "$TMP/climb.csv"
"$CHECK" "$TMP/climb.csv" 0.15 >/dev/null; expect "monotonic climb" 1 "$?"

# Drop tail (aggressive GC) counts as plateau (one-sided: not growing) -> exit 0
{ echo "epoch,rss_kb";
  for i in $(seq 1 20); do echo "$i,300000"; done;
  for i in $(seq 21 40); do echo "$i,180000"; done; } > "$TMP/drop.csv"
"$CHECK" "$TMP/drop.csv" 0.15 >/dev/null; expect "dropping tail" 0 "$?"

# Too few samples -> exit 2
{ echo "epoch,rss_kb"; echo "1,100000"; echo "2,110000"; } > "$TMP/tiny.csv"
"$CHECK" "$TMP/tiny.csv" 0.15 >/dev/null; expect "insufficient samples" 2 "$?"

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
