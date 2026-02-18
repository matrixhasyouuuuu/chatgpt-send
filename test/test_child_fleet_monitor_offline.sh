#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
sleep_running_pid=""
sleep_stuck_pid=""
cleanup() {
  if [[ -n "${sleep_running_pid:-}" ]]; then
    kill "$sleep_running_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${sleep_stuck_pid:-}" ]]; then
    kill "$sleep_stuck_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pool="$tmp/pool"
mkdir -p "$pool/logs"

d_ok="$pool/logs/a_ok/r_ok"
d_fail="$pool/logs/a_fail/r_fail"
d_running="$pool/logs/a_running/r_running"
d_stuck="$pool/logs/a_stuck/r_stuck"
d_orphan="$pool/logs/a_orphan/r_orphan"
mkdir -p "$d_ok" "$d_fail" "$d_running" "$d_stuck" "$d_orphan"

# DONE_OK
printf '%s\n' "0" >"$d_ok/r_ok.exit"
printf '%s\n' "CHILD_RESULT: ok" >"$d_ok/r_ok.last.txt"
cat >"$d_ok/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

# DONE_FAIL
printf '%s\n' "2" >"$d_fail/r_fail.exit"
printf '%s\n' "CHILD_RESULT: fail" >"$d_fail/r_fail.last.txt"
cat >"$d_fail/child_result.json" <<'JSON'
{"status":"E_CHILD_FAILED","exit_code":2}
JSON

# RUNNING
sleep 60 &
sleep_running_pid=$!
printf '%s\n' "$sleep_running_pid" >"$d_running/r_running.pid"
printf '%s\n' "[child] ITER_STATUS step=execute status=running" >"$d_running/r_running.status.log"

# STUCK (alive pid, but old status mtime)
sleep 60 &
sleep_stuck_pid=$!
printf '%s\n' "$sleep_stuck_pid" >"$d_stuck/r_stuck.pid"
printf '%s\n' "[child] ITER_STATUS step=execute status=running" >"$d_stuck/r_stuck.status.log"
touch -d '10 minutes ago' "$d_stuck/r_stuck.status.log"

# ORPHANED (dead pid, no terminal artifacts)
printf '%s\n' "999999" >"$d_orphan/r_orphan.pid"

registry="$pool/fleet_registry.jsonl"
cat >"$registry" <<JSONL
{"run_id":"r_ok","run_dir":"$d_ok","agent_id":"a_ok","assigned_chat_url":"https://chatgpt.com/c/ok"}
broken-json-line
JSONL

monitor_log="$pool/fleet.monitor.log"
summary_json="$pool/fleet.summary.json"
summary_csv="$pool/fleet.summary.csv"

set +e
"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 4 \
  --stuck-after-sec 30 \
  --registry-file "$registry" \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" \
  --summary-csv "$summary_csv" >"$tmp/monitor.out" 2>&1
rc=$?
set -e

[[ "$rc" == "124" ]]

test -s "$summary_json"
test -s "$summary_csv"
rg -q -- 'event=timeout' "$monitor_log"
rg -q -- 'event=registry_warn code=W_LEDGER_CORRUPT_LINE_SKIPPED bad_lines=1' "$monitor_log"

python3 - "$summary_json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj["total"] == 5, obj
assert obj["done_ok"] == 1, obj
assert obj["done_fail"] == 1, obj
assert obj["running"] == 2, obj
assert obj["stuck"] == 1, obj
assert obj["orphaned"] == 1, obj
classes = {row["run_id"]: row["state_class"] for row in obj["agents"]}
assert classes["r_ok"] == "DONE_OK", classes
assert classes["r_fail"] == "DONE_FAIL", classes
assert classes["r_running"] == "RUNNING", classes
assert classes["r_stuck"] == "STUCK", classes
assert classes["r_orphan"] == "ORPHANED", classes
PY

echo "OK"
