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

# Child #1 already done.
printf '%s\n' "0" >"$d1/r1.exit"
printf '%s\n' "CHILD_RESULT: done a1" >"$d1/r1.last.txt"
cat >"$d1/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

# Child #2 starts running, then becomes done.
sleep 30 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" >"$d2/r2.pid"
printf '%s\n' "[child] ITER_STATUS step=execute status=running" >"$d2/r2.status.log"
printf '%s\n' "CHILD_RESULT: pending a2" >"$d2/r2.last.txt"

monitor_log="$pool/fleet.monitor.log"
summary_json="$pool/fleet.summary.json"
heartbeat_file="$pool/fleet.heartbeat"
events_jsonl="$pool/fleet.events.jsonl"

"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 1 \
  --timeout-sec 15 \
  --stuck-after-sec 20 \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" >"$tmp/monitor.out" 2>&1 &
mon_pid=$!

deadline=$(( $(date +%s) + 6 ))
while [[ ! -s "$heartbeat_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "heartbeat file not created: $heartbeat_file" >&2
    exit 1
  fi
  sleep 0.2
done

sleep 2
printf '%s\n' "CHILD_RESULT: done a2" >"$d2/r2.last.txt"
cat >"$d2/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON
printf '%s\n' "0" >"$d2/r2.exit"

wait "$mon_pid"
kill "$sleep_pid" >/dev/null 2>&1 || true

rg -q -- 'FLEET_HEARTBEAT write ts_ms=' "$monitor_log"
test -s "$events_jsonl"
test -s "$summary_json"

python3 - "$heartbeat_file" "$events_jsonl" "$summary_json" <<'PY'
import json
import pathlib
import sys

heartbeat_path = pathlib.Path(sys.argv[1])
events_path = pathlib.Path(sys.argv[2])
summary_path = pathlib.Path(sys.argv[3])

hb = heartbeat_path.read_text(encoding="utf-8").strip()
if not hb.startswith("ts_ms="):
    raise SystemExit(f"unexpected heartbeat format: {hb!r}")
ts = hb.split("=", 1)[1].strip()
if not ts.isdigit():
    raise SystemExit(f"heartbeat ts is not numeric: {ts!r}")

events = [json.loads(line) for line in events_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if not events:
    raise SystemExit("events jsonl is empty")

r2_states = [e.get("new_state") for e in events if e.get("run_id") == "r2"]
if "RUNNING" not in r2_states:
    raise SystemExit(f"r2 RUNNING transition missing: {r2_states}")
if "DONE_OK" not in r2_states:
    raise SystemExit(f"r2 DONE_OK transition missing: {r2_states}")

summary = json.loads(summary_path.read_text(encoding="utf-8"))
if summary.get("done_ok") != 2:
    raise SystemExit(f"expected done_ok=2, got {summary.get('done_ok')}")
if summary.get("stuck") != 0 or summary.get("orphaned") != 0:
    raise SystemExit(f"unexpected stuck/orphaned: {summary}")
PY

echo "OK"
