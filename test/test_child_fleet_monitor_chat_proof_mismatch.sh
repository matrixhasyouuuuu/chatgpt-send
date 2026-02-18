#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
run="$tmp/runs/a1/r1"
mkdir -p "$pool" "$run"

printf '%s\n' "12345" >"$run/r1.pid"
printf '%s\n' "[child] ITER_STATUS step=report status=done" >"$run/r1.status.log"
printf '%s\n' "CHILD_BROWSER_USED: yes ; EVIDENCE: https://chatgpt.com/c/bbb" >"$run/r1.log"
printf '%s\n' "CHILD_RESULT: done" >"$run/r1.last.txt"
printf '%s\n' "0" >"$run/r1.exit"
cat >"$run/child_result.json" <<'JSON'
{"status":"OK","exit_code":0,"pinned_route_url":"https://chatgpt.com/c/bbb","specialist_chat_url":"https://chatgpt.com/c/bbb"}
JSON

roster="$pool/fleet_roster.jsonl"
cat >"$roster" <<JSONL
{"run_id":"r1","run_dir":"$run","result_json":"$run/child_result.json","pid_file":"$run/r1.pid","status_file":"$run/r1.status.log","log_file":"$run/r1.log","assigned_chat_url":"https://chatgpt.com/c/aaa","agent_id":"a1"}
JSONL

summary_json="$pool/fleet.summary.json"

"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 10 \
  --stuck-after-sec 10 \
  --registry-file "$pool/fleet_registry.jsonl" \
  --roster-jsonl "$roster" \
  --summary-json "$summary_json" >"$tmp/monitor.out" 2>&1

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if obj.get("chat_ok_total") != 0:
    raise SystemExit(f"expected chat_ok_total=0, got {obj.get('chat_ok_total')}")
if obj.get("chat_mismatch_total") != 1:
    raise SystemExit(f"expected chat_mismatch_total=1, got {obj.get('chat_mismatch_total')}")
if obj.get("chat_unknown_total") != 0:
    raise SystemExit(f"expected chat_unknown_total=0, got {obj.get('chat_unknown_total')}")
agents = obj.get("agents") or []
if len(agents) != 1:
    raise SystemExit(f"expected 1 agent, got {len(agents)}")
row = agents[0]
if row.get("chat_proof") != "mismatch":
    raise SystemExit(f"expected chat_proof=mismatch, got {row.get('chat_proof')}")
if row.get("assigned_chat_url_norm") != "https://chatgpt.com/c/aaa":
    raise SystemExit(f"bad assigned_chat_url_norm: {row.get('assigned_chat_url_norm')}")
if row.get("observed_chat_url_norm") != "https://chatgpt.com/c/bbb":
    raise SystemExit(f"bad observed_chat_url_norm: {row.get('observed_chat_url_norm')}")
PY

echo "OK"
