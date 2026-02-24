#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT_DIR/scripts/pool_report.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
run="$pool/logs/a1/r1"
mkdir -p "$run"

printf '%s\n' 'CHILD_RESULT: early abort report test' >"$run/r1.last.txt"

cat >"$pool/fleet.summary.json" <<JSON
{
  "done_ok": 0,
  "done_fail": 0,
  "stuck": 1,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "disk_free_pct": 48,
  "chat_ok_total": 0,
  "chat_mismatch_total": 0,
  "chat_unknown_total": 0,
  "agents": [
    {
      "agent_id": "1",
      "run_id": "r1",
      "state_class": "STUCK",
      "reason": "confirmed_stuck",
      "exit_code": 1,
      "chat_proof": "ok",
      "assigned_chat_url_norm": "https://chatgpt.com/c/aaa",
      "observed_chat_url_norm": "https://chatgpt.com/c/aaa",
      "last_file": "$run/r1.last.txt",
      "result_json": "$run/child_result.json",
      "log_file": "$run/r1.log"
    }
  ]
}
JSON

cat >"$pool/summary.jsonl" <<'JSONL'
{"agent":1,"attempt":1,"child_run_id":"r1","duration_sec":"11","exit_code":"1"}
JSONL

: >"$pool/.early_abort"
printf '%s\n' 'reason=stuck_or_orphaned stuck=1 orphaned=0 confirm_ticks=2 bad_ticks=2' >"$pool/.early_abort.reason"
printf '%s\n' "1	r1	STUCK" >"$pool/.early_abort.ids"
cat >"$pool/early_abort.meta.json" <<'JSON'
{
  "reason": "stuck_or_orphaned",
  "stuck": 1,
  "orphaned": 0,
  "bad_ticks": 2,
  "confirm_ticks": 2,
  "ids_count": 1,
  "ts_utc": "2026-02-18T00:00:00+00:00"
}
JSON

out_md="$pool/pool_report.md"
out_json="$pool/pool_report.json"

"$REPORT" \
  --pool-run-dir "$pool" \
  --fleet-summary-json "$pool/fleet.summary.json" \
  --summary-jsonl "$pool/summary.jsonl" \
  --out-md "$out_md" \
  --out-json "$out_json" \
  --gate-status FAIL \
  --gate-reason early_abort

test -s "$out_md"
test -s "$out_json"
rg -q -- '^## Early Abort' "$out_md"
rg -q -- '`triggered`: `1`' "$out_md"
rg -q -- 'blame_agent_id' "$out_md"
rg -q -- 'early_abort_blame' "$out_md"

python3 - "$out_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
ea = obj.get("early_abort") or {}
if int(ea.get("triggered", 0)) != 1:
    raise SystemExit("early_abort.triggered != 1")
if int(ea.get("ids_count", 0)) != 1:
    raise SystemExit("early_abort.ids_count != 1")
ids = ea.get("ids") or []
if len(ids) != 1 or str(ids[0].get("agent_id")) != "1":
    raise SystemExit("unexpected early_abort.ids payload")
rows = obj.get("rows") or []
if not rows or int(rows[0].get("early_abort_blame", 0)) != 1:
    raise SystemExit("row missing early_abort_blame=1")
PY

echo "OK"
