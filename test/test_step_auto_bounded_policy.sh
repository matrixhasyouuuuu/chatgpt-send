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
FP="fp-bounded-123"
CKPT="SPC-2099-01-01T00:00:00Z-bounded"
NOW_TS="$(date +%s)"

cat >"$STATUS_JSON" <<EOF
{
  "schema_version":"status.v1",
  "ts":$NOW_TS,
  "status":"ready",
  "can_send":1,
  "blockers":[],
  "warnings":[],
  "next_actions":[],
  "operator_summary":{"state":"READY","why":"ok_ready","next":"STEP_READ","note":"ready","confidence":"high"},
  "multi_tabs":{"present":false,"tab_count":1,"severity":"none","reason":"","hint":""},
  "checkpoint":{"chat_url":"$URL","checkpoint_id":"$CKPT","fingerprint_v1":"$FP"},
  "latest_run":{"exists":0,"run_dir":"","run_id":"","summary_exists":0,"manifest_exists":0,"evidence_dir":"","reason":"","outcome":"","exit_status":0,"ts_end":null},
  "ops":{"chat_route_ok":1,"cdp_ok":1,"strict_single_chat":1,"tab_count":1,"target_chat_url":"$URL","work_chat_url":"$URL","last_protocol_event":{},"pending_details":{"pending_unacked":0},"ledger_last":{}}
}
EOF

cat >"$TOKEN_JSON" <<EOF
{"schema_version":"preflight_token.v1","ts":$NOW_TS,"target_chat_url":"$URL","tab_fingerprint_v1":"$FP","checkpoint_id":"$CKPT"}
EOF

MOCK_BIN="$tmp/mock_chatgpt_send"
cat >"$MOCK_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--status" && "${2:-}" == "--json" ]]; then
  cat "$STATUS_JSON"
  exit 0
fi
if [[ "${1:-}" == "--ack" ]]; then
  echo "ACK_MOCK"
  exit 0
fi
echo "unexpected mock call: $*" >&2
exit 99
EOF
chmod +x "$MOCK_BIN"

export ROOT STATUS_JSON
export RUN_ID="run-test-bounded-auto"
export CHATGPT_SEND_TRANSPORT="mock"
export STEP_MAX_STEPS="1"
export SCRIPT_PATH="$MOCK_BIN"
export OUTPUT_JSON=1

# shellcheck source=/dev/null
source "$COMMANDS_SH"

# 1) Ready + fresh preflight + message => planner next=DELEGATE_SEND_PIPELINE, but bounded auto must not send.
set +e
( STEP_ACTION=auto STEP_MESSAGE="hello" chatgpt_send_step_command ) >"$tmp/auto_need_send.json"
rc=$?
set -e
python3 - "$tmp/auto_need_send.json" "$rc" <<'PY'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
rc = int(sys.argv[2])
assert rc == 74, rc
auto = o.get("auto") or {}
assert auto.get("stop_reason") == "need_send", auto
assert auto.get("forbidden_action_detected") == "DELEGATE_SEND_PIPELINE", auto
assert auto.get("steps_executed") == 0, auto
assert ((o.get("decision") or {}).get("next") or {}).get("action_id") == "DELEGATE_SEND_PIPELINE"
PY

# 2) Ready + no message => bounded auto returns no-op metadata instead of E_STEP_MESSAGE_REQUIRED.
set +e
( STEP_ACTION=auto STEP_MESSAGE="" chatgpt_send_step_command ) >"$tmp/auto_need_safe_action.json"
rc=$?
set -e
python3 - "$tmp/auto_need_safe_action.json" "$rc" <<'PY'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
rc = int(sys.argv[2])
assert rc == 0, rc
auto = o.get("auto") or {}
assert auto.get("stop_reason") == "need_safe_action", auto
assert auto.get("forbidden_action_detected") in ("", None), auto
assert auto.get("steps_executed") == 0, auto
assert ((o.get("decision") or {}).get("next") or {}).get("action_id") == "STEP_PREFLIGHT"
PY

# 3) Planner exposes autostep_allowed flags in recommended_actions.
chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/plan_flags.json"
python3 - "$tmp/plan_flags.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1], encoding="utf-8"))
recs = (o.get("decision") or {}).get("recommended_actions") or []
assert recs, recs
first = recs[0]
assert first.get("id") == "DELEGATE_SEND_PIPELINE", first
assert first.get("autostep_allowed") is False, first
PY

echo "OK"
