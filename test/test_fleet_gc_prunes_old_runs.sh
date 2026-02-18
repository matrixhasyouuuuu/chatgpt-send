#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GC="$ROOT_DIR/scripts/fleet_gc.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

runs_root="$tmp/runs"
mkdir -p "$runs_root"

for n in 1 2 3 4 5; do
  d="$runs_root/pool_$n"
  mkdir -p "$d"
  printf '{}\n' >"$d/fleet.summary.json"
  printf 'x\n' >"$d/payload.txt"
done

# Ensure predictable ordering: pool_5 newest, pool_1 oldest.
touch -d '10 hours ago' "$runs_root/pool_1"
touch -d '8 hours ago' "$runs_root/pool_2"
touch -d '6 hours ago' "$runs_root/pool_3"
touch -d '4 hours ago' "$runs_root/pool_4"
touch -d '2 hours ago' "$runs_root/pool_5"

# Active run must survive, even if old.
touch "$runs_root/pool_2/.pool.active"
touch -d '8 hours ago' "$runs_root/pool_2/.pool.active" "$runs_root/pool_2"

out="$("$GC" --root "$runs_root" --keep-last 1 --keep-hours 0 --max-total-mb 0 2>&1)"

echo "$out" | rg -q -- '^GC_START '
echo "$out" | rg -q -- 'GC_SKIP_ACTIVE dir=.*/pool_2'
echo "$out" | rg -q -- 'GC_DELETE dir='
echo "$out" | rg -q -- '^GC_SUMMARY '

test -d "$runs_root/pool_2"
test -d "$runs_root/pool_5"
test ! -d "$runs_root/pool_1"
test ! -d "$runs_root/pool_3"
test ! -d "$runs_root/pool_4"

echo "OK"
