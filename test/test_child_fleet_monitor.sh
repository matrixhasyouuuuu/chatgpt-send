#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
d1="$pool/logs/a1_arch/r1"
d2="$pool/logs/a2_sec/r2"
mkdir -p "$d1" "$d2"

# Child #1 already completed.
printf '%s\n' "11111" >"$d1/r1.pid"
printf '%s\n' "0" >"$d1/r1.exit"
printf '%s\n' "CHILD_RESULT: A1_ARCH_DONE" >"$d1/r1.last.txt"
cat >"$d1/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

# Child #2 starts as running and completes later.
sleep 30 &
sleep_pid=$!
trap 'kill "$sleep_pid" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
printf '%s\n' "$sleep_pid" >"$d2/r2.pid"
printf '%s\n' "[child] ITER_STATUS step=execute status=running" >"$d2/r2.status.log"
printf '%s\n' "CHILD_RESULT: pending" >"$d2/r2.last.txt"

monitor_log="$pool/fleet.monitor.log"
summary_json="$pool/fleet.summary.json"
summary_csv="$pool/fleet.summary.csv"

"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 15 \
  --stuck-after-sec 20 \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" \
  --summary-csv "$summary_csv" >"$tmp/monitor.out" 2>&1 &
mon_pid=$!

sleep 2
printf '%s\n' "CHILD_RESULT: A2_SEC_DONE" >"$d2/r2.last.txt"
cat >"$d2/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON
printf '%s\n' "0" >"$d2/r2.exit"

wait "$mon_pid"

kill "$sleep_pid" >/dev/null 2>&1 || true

rg -q -- 'event=start ' "$monitor_log"
rg -q -- 'event=progress total=2 done_ok=2 done_fail=0 running=0 stuck=0 orphaned=0 unknown=0' "$monitor_log"
rg -q -- 'event=child_done agent=a1_arch run_id=r1 exit_code=0' "$monitor_log"
rg -q -- 'event=child_done agent=a2_sec run_id=r2 exit_code=0' "$monitor_log"
rg -q -- 'event=done total=2 ok=2 failed=0' "$monitor_log"
test -s "$summary_json"
test -s "$summary_csv"

python3 - "$summary_json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj["total"] == 2, obj
assert obj["done"] == 2, obj
assert obj["failed"] == 0, obj
assert obj["done_ok"] == 2, obj
assert obj["done_fail"] == 0, obj
assert obj["orphaned"] == 0, obj
states = {row["run_id"]: row["state_class"] for row in obj["agents"]}
assert states == {"r1": "DONE_OK", "r2": "DONE_OK"}, states
PY

echo "OK"
