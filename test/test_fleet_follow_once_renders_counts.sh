#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLLOW="$ROOT_DIR/scripts/fleet_follow.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

summary_json="$tmp/fleet.summary.json"
cat >"$summary_json" <<'JSON'
{
  "total": 5,
  "done_ok": 2,
  "done_fail": 1,
  "running": 1,
  "stuck": 0,
  "orphaned": 0,
  "unknown": 1,
  "disk_status": "ok",
  "chat_ok_total": 4,
  "chat_mismatch_total": 1,
  "chat_unknown_total": 0
}
JSON

out="$("$FOLLOW" --summary-json "$summary_json" --once --no-ansi)"
echo "$out" | rg -q -- '^PROGRESS '
echo "$out" | rg -q -- 'total=5'
echo "$out" | rg -q -- 'ok=2'
echo "$out" | rg -q -- 'fail=1'
echo "$out" | rg -q -- 'running=1'
echo "$out" | rg -q -- 'unknown=1'
echo "$out" | rg -q -- 'pending=2'
echo "$out" | rg -q -- 'status=running'

echo "OK"
