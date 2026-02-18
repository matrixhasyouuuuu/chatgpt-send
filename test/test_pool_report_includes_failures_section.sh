#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$ROOT_DIR/scripts/pool_report.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool"
run="$pool/logs/a1/r1"
mkdir -p "$run"

printf '%s\n' 'CHILD_RESULT: fail branch example' >"$run/r1.last.txt"

cat >"$pool/fleet.summary.json" <<JSON
{
  "done_ok": 0,
  "done_fail": 1,
  "stuck": 0,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "disk_free_pct": 42,
  "chat_ok_total": 0,
  "chat_mismatch_total": 1,
  "chat_unknown_total": 0,
  "agents": [
    {
      "agent_id": "a1",
      "run_id": "r1",
      "state_class": "DONE_FAIL",
      "reason": "assigned_chat_mismatch",
      "exit_code": 1,
      "chat_proof": "mismatch",
      "assigned_chat_url_norm": "https://chatgpt.com/c/aaa",
      "observed_chat_url_norm": "https://chatgpt.com/c/bbb",
      "last_file": "$run/r1.last.txt",
      "result_json": "$run/child_result.json",
      "log_file": "$run/r1.log"
    }
  ]
}
JSON

cat >"$pool/summary.jsonl" <<'JSONL'
{"agent":1,"attempt":1,"child_run_id":"r1","duration_sec":"12","exit_code":"1"}
JSONL

out_md="$pool/pool_report.md"
out_json="$pool/pool_report.json"

"$REPORT" \
  --pool-run-dir "$pool" \
  --fleet-summary-json "$pool/fleet.summary.json" \
  --summary-jsonl "$pool/summary.jsonl" \
  --out-md "$out_md" \
  --out-json "$out_json" \
  --gate-status FAIL \
  --gate-reason chat_mismatch

test -s "$out_md"
test -s "$out_json"
rg -q -- '^## Failures / Alerts' "$out_md"
rg -q -- 'chat_proof=mismatch' "$out_md"
rg -q -- 'POOL_FLEET_GATE_REASON' "$out_md"

echo "OK"
