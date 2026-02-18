#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
run1="$tmp/runs/a1/r1"
run2="$tmp/runs/a2/r2"
mkdir -p "$pool" "$run1" "$run2"

printf '%s\n' "11111" >"$run1/r1.pid"
printf '%s\n' "[child] ITER_STATUS step=report status=done" >"$run1/r1.status.log"
printf '%s\n' "child log a1" >"$run1/r1.log"
printf '%s\n' "CHILD_RESULT: roster done a1" >"$run1/r1.last.txt"
printf '%s\n' "0" >"$run1/r1.exit"
cat >"$run1/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

printf '%s\n' "22222" >"$run2/r2.pid"
printf '%s\n' "[child] ITER_STATUS step=report status=done" >"$run2/r2.status.log"
printf '%s\n' "child log a2" >"$run2/r2.log"
printf '%s\n' "CHILD_RESULT: roster done a2" >"$run2/r2.last.txt"
printf '%s\n' "0" >"$run2/r2.exit"
cat >"$run2/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

roster="$pool/fleet_roster.jsonl"
cat >"$roster" <<JSONL
{"run_id":"r1","run_dir":"$run1","result_json":"$run1/child_result.json","pid_file":"$run1/r1.pid","status_file":"$run1/r1.status.log","log_file":"$run1/r1.log","assigned_chat_url":"https://chatgpt.com/c/roster-a1","agent_id":"a1"}
{"run_id":"r2","run_dir":"$run2","result_json":"$run2/child_result.json","pid_file":"$run2/r2.pid","status_file":"$run2/r2.status.log","log_file":"$run2/r2.log","assigned_chat_url":"https://chatgpt.com/c/roster-a2","agent_id":"a2"}
JSONL

monitor_log="$pool/fleet.monitor.log"
summary_json="$pool/fleet.summary.json"
summary_csv="$pool/fleet.summary.csv"

"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 10 \
  --stuck-after-sec 10 \
  --registry-file "$pool/fleet_registry.jsonl" \
  --roster-jsonl "$roster" \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" \
  --summary-csv "$summary_csv" >"$tmp/monitor.out" 2>&1

test -s "$summary_json"
test -s "$summary_csv"
rg -q -- 'event=done total=2 ok=2 failed=0' "$monitor_log"

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if obj.get("total") != 2:
    raise SystemExit(f"expected total=2, got {obj.get('total')}")
if obj.get("done_ok") != 2:
    raise SystemExit(f"expected done_ok=2, got {obj.get('done_ok')}")
if obj.get("done_fail") != 0:
    raise SystemExit(f"expected done_fail=0, got {obj.get('done_fail')}")
if obj.get("missing_artifacts_total") != 0:
    raise SystemExit(f"expected missing_artifacts_total=0, got {obj.get('missing_artifacts_total')}")
sources = obj.get("discovery_sources") or {}
if sources.get("registry") != 0:
    raise SystemExit(f"expected discovery_sources.registry=0, got {sources.get('registry')}")
if sources.get("roster") != 2:
    raise SystemExit(f"expected discovery_sources.roster=2, got {sources.get('roster')}")
if sources.get("merged") != 2:
    raise SystemExit(f"expected discovery_sources.merged=2, got {sources.get('merged')}")
states = {row.get("run_id"): row.get("state_class") for row in obj.get("agents", [])}
if states != {"r1": "DONE_OK", "r2": "DONE_OK"}:
    raise SystemExit(f"unexpected state classes: {states}")
PY

echo "OK"
