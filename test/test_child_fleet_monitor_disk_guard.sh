#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/scripts/child_fleet_monitor.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
d1="$pool/logs/a1/r1"
mkdir -p "$d1"

printf '%s\n' "0" >"$d1/r1.exit"
printf '%s\n' "CHILD_RESULT: disk guard done" >"$d1/r1.last.txt"
cat >"$d1/child_result.json" <<'JSON'
{"status":"OK","exit_code":0}
JSON

monitor_log="$pool/fleet.monitor.log"
summary_json="$pool/fleet.summary.json"

FLEET_DISK_FREE_WARN_PCT=100 \
FLEET_DISK_FREE_FAIL_PCT=100 \
"$MON" \
  --pool-run-dir "$pool" \
  --poll-sec 1 \
  --heartbeat-sec 0 \
  --timeout-sec 10 \
  --stuck-after-sec 10 \
  --monitor-log "$monitor_log" \
  --summary-json "$summary_json" >"$tmp/monitor.out" 2>&1

test -s "$summary_json"
rg -q -- 'event=disk_status status=fail' "$monitor_log"

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if obj.get("disk_status") != "fail":
    raise SystemExit(f"expected disk_status=fail, got {obj.get('disk_status')}")
if not isinstance(obj.get("disk_free_pct"), int):
    raise SystemExit("disk_free_pct must be int in summary")
if not isinstance(obj.get("disk_avail_kb"), int):
    raise SystemExit("disk_avail_kb must be int in summary")
if obj.get("done_ok") != 1:
    raise SystemExit(f"expected done_ok=1, got {obj.get('done_ok')}")
PY

echo "OK"
