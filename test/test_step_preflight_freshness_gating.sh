#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMANDS_SH="$SCRIPT_DIR/bin/lib/chatgpt_send/commands.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ROOT="$tmp/root"
mkdir -p "$ROOT/state/status" "$ROOT/ux"
cp "$SCRIPT_DIR/ux/error_registry.py" "$ROOT/ux/error_registry.py"

STATUS_JSON="$ROOT/state/status/status.v1.json"
TOKEN_JSON="$ROOT/state/status/preflight_token.v1.json"
URL="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
FP="fp-test-123"
CKPT="SPC-2099-01-01T00:00:00Z-deadbeef"

NOW_TS="$(date +%s)"
cat >"$STATUS_JSON" <<EOF
{
  "schema_version": "status.v1",
  "ts": $NOW_TS,
  "blockers": [],
  "warnings": [],
  "next_actions": [],
  "checkpoint": {
    "chat_url": "$URL",
    "checkpoint_id": "$CKPT",
    "fingerprint_v1": "$FP"
  },
  "latest_run": {
    "exists": 0,
    "run_dir": "",
    "run_id": "",
    "summary_exists": 0,
    "manifest_exists": 0,
    "evidence_dir": "",
    "reason": "",
    "outcome": "",
    "exit_status": 0,
    "ts_end": null
  },
  "ops": {
    "chat_route_ok": 1,
    "cdp_ok": 1,
    "strict_single_chat": 1,
    "tab_count": 1,
    "target_chat_url": "$URL",
    "work_chat_url": "$URL",
    "last_protocol_event": {},
    "pending_details": {"pending_unacked": 0},
    "ledger_last": {}
  }
}
EOF

export ROOT
export RUN_ID="run-test-preflight"
export CHATGPT_SEND_TRANSPORT="mock"
export STEP_MAX_STEPS="1"

# shellcheck source=/dev/null
source "$COMMANDS_SH"

assert_plan() {
  local json_file="$1"
  local want_block="$2"
  local want_error="$3"
  local want_next="$4"
  python3 - "$json_file" "$want_block" "$want_error" "$want_next" <<'PY'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
want_block, want_error, want_next = sys.argv[2:]
block = (o.get("block") or {}).get("reason") or ""
error = (o.get("block") or {}).get("error_code") or ""
next_action = (((o.get("decision") or {}).get("next") or {}).get("action_id")) or ""
assert block == want_block, (block, want_block)
assert error == want_error, (error, want_error)
assert next_action == want_next, (next_action, want_next)
PY
}

# 1) Missing token => delegated send blocked until preflight
rm -f "$TOKEN_JSON"
chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/plan_missing.json"
assert_plan "$tmp/plan_missing.json" "SOFT_BLOCK_RETRYABLE" "E_PREFLIGHT_STALE" "STEP_PREFLIGHT"
python3 - "$tmp/plan_missing.json" <<'PY'
import json, sys
p = (json.load(open(sys.argv[1], encoding="utf-8")).get("preflight") or {})
assert p.get("fresh") is False
assert p.get("reason_not_fresh") == "missing"
PY

# 2) Fresh token => delegated send allowed
cat >"$TOKEN_JSON" <<EOF
{"schema_version":"preflight_token.v1","ts":$NOW_TS,"target_chat_url":"$URL","tab_fingerprint_v1":"$FP","checkpoint_id":"$CKPT"}
EOF
CHATGPT_SEND_PREFLIGHT_TTL_SEC=60 chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/plan_fresh.json"
assert_plan "$tmp/plan_fresh.json" "" "" "DELEGATE_SEND_PIPELINE"
python3 - "$tmp/plan_fresh.json" <<'PY'
import json, sys
p = (json.load(open(sys.argv[1], encoding="utf-8")).get("preflight") or {})
assert p.get("fresh") is True
assert (p.get("reason_not_fresh") or "") == ""
PY

# 3) Target mismatch (fresh ts but wrong target) => block delegated send
cat >"$TOKEN_JSON" <<EOF
{"schema_version":"preflight_token.v1","ts":$NOW_TS,"target_chat_url":"https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tab_fingerprint_v1":"$FP","checkpoint_id":"$CKPT"}
EOF
CHATGPT_SEND_PREFLIGHT_TTL_SEC=60 chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/plan_mismatch.json"
assert_plan "$tmp/plan_mismatch.json" "SOFT_BLOCK_RETRYABLE" "E_PREFLIGHT_STALE" "STEP_PREFLIGHT"
python3 - "$tmp/plan_mismatch.json" <<'PY'
import json, sys
p = (json.load(open(sys.argv[1], encoding="utf-8")).get("preflight") or {})
assert p.get("fresh") is False
assert p.get("reason_not_fresh") == "target_mismatch"
PY

# 4) multiple_chat_tabs warning (route OK) should not hard-block delegated send
python3 - "$STATUS_JSON" <<'PY'
import json, sys
p = sys.argv[1]
o = json.load(open(p, encoding="utf-8"))
o["warnings"] = ["multiple_chat_tabs"]
o["ops"]["tab_count"] = 3
o["multi_tabs"] = {
    "present": True,
    "tab_count": 3,
    "severity": "warning",
    "reason": "route_ok_multiple_tabs",
    "hint": "warning only"
}
json.dump(o, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
cat >"$TOKEN_JSON" <<EOF
{"schema_version":"preflight_token.v1","ts":$NOW_TS,"target_chat_url":"$URL","tab_fingerprint_v1":"$FP","checkpoint_id":"$CKPT"}
EOF
CHATGPT_SEND_PREFLIGHT_TTL_SEC=60 chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/plan_multiwarn.json"
assert_plan "$tmp/plan_multiwarn.json" "" "" "DELEGATE_SEND_PIPELINE"
python3 - "$tmp/plan_multiwarn.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
notes = (o.get("hints") or {}).get("operator_notes") or []
gates = ((((o.get("decision") or {}).get("next") or {}).get("gates")) or [])
state_multi = ((o.get("state") or {}).get("multi_tabs") or {})
assert any("лишние ChatGPT" in str(x) for x in notes), notes
assert "multi_tabs_present=true" in gates, gates
assert "multi_tabs_severity=warning" in gates, gates
assert state_multi.get("present") is True, state_multi
assert state_multi.get("severity") == "warning", state_multi
PY

echo "OK"
