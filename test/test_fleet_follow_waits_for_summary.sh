#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLLOW="$ROOT_DIR/scripts/fleet_follow.sh"

tmp="$(mktemp -d)"
follow_pid=""
cleanup() {
  if [[ -n "${follow_pid:-}" ]]; then
    kill "$follow_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

summary_json="$tmp/fleet.summary.json"
follow_out="$tmp/follow.out"

"$FOLLOW" --summary-json "$summary_json" --tick-ms 50 --no-ansi >"$follow_out" 2>&1 &
follow_pid="$!"

for _ in $(seq 1 40); do
  if rg -q '^FLEET_FOLLOW_WAIT ' "$follow_out"; then
    break
  fi
  sleep 0.05
done
rg -q '^FLEET_FOLLOW_WAIT ' "$follow_out"

cat >"$summary_json" <<'JSON'
{
  "total": 1,
  "done_ok": 1,
  "done_fail": 0,
  "running": 0,
  "stuck": 0,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "disk_free_pct": 42,
  "chat_ok_total": 1,
  "chat_mismatch_total": 0,
  "chat_unknown_total": 0
}
JSON

wait "$follow_pid"
rc=$?
follow_pid=""
[[ "$rc" == "0" ]]

rg -q '^PROGRESS ' "$follow_out"
rg -q '^FLEET_FOLLOW_DONE ' "$follow_out"

echo "OK"

