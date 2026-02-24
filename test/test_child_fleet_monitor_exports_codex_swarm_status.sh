#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
sleep_pid=""
cleanup() {
  if [[ -n "${sleep_pid:-}" ]]; then
    kill "$sleep_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pool="$tmp/pool"
d1="$pool/logs/a1/r1"
d2="$pool/logs/a2/r2"
mkdir -p "$d1" "$d2"

# Agent 1 done
printf '%s\n' "0" >"$d1/r1.exit"
printf '%s\n' "CHILD_RESULT: A1_DONE" >"$d1/r1.last.txt"
cat >"$d1/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

# Agent 2 running
sleep 30 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" >"$d2/r2.pid"
printf '%s\n' "[child] ITER_STATUS step=execute status=running" >"$d2/r2.status.log"
printf '%s\n' "CHILD_RESULT: pending" >"$d2/r2.last.txt"

summary_json="$pool/fleet.summary.json"
summary_csv="$pool/fleet.summary.csv"
monitor_log="$pool/fleet.monitor.log"
codex_swarm_json="$tmp/codex-swarm-status.json"

set +e
CODEX_SWARM_STATUS_FILE="$codex_swarm_json" "$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 3 \
  --stuck-after-sec 60 \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" \
  --summary-csv "$summary_csv" >"$tmp/monitor.out" 2>&1
rc=$?
set -e

[[ "$rc" == "124" ]]
test -s "$codex_swarm_json"
rg -q -- 'codex_swarm_status_json=' "$monitor_log"

python3 - "$codex_swarm_json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj["version"] == "swarm-status.v1", obj
s = obj["summary"]
assert s["total"] == 2, s
assert s["done"] == 1, s
assert s["running"] == 1, s
assert s["failed"] == 0, s
assert s["waiting"] == 0, s
agents = {a["id"]: a for a in obj["agents"]}
assert agents["a1"]["state"] == "done", agents
assert agents["a2"]["state"] == "running", agents
PY

echo "OK"
