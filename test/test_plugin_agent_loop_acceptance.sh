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
FP="fp-accept-123"
CKPT="SPC-2099-01-01T00:00:00Z-cafe"
NOW_TS="$(date +%s)"

write_status_fixture() {
  local scenario="$1"
  case "$scenario" in
    ready)
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
      ;;
    ack_blocked)
      cat >"$STATUS_JSON" <<EOF
{
  "schema_version":"status.v1",
  "ts":$NOW_TS,
  "status":"blocked",
  "can_send":0,
  "blockers":["reply_unacked"],
  "warnings":[],
  "next_actions":["Сначала подтвердите прочтение последнего ответа (--ack)."],
  "operator_summary":{"state":"BLOCKED","why":"ack_required","next":"ACK","note":"ack first","confidence":"high"},
  "multi_tabs":{"present":false,"tab_count":1,"severity":"none","reason":"","hint":""},
  "checkpoint":{"chat_url":"$URL","checkpoint_id":"$CKPT","fingerprint_v1":"$FP"},
  "latest_run":{"exists":0,"run_dir":"","run_id":"","summary_exists":0,"manifest_exists":0,"evidence_dir":"","reason":"","outcome":"","exit_status":0,"ts_end":null},
  "ops":{"chat_route_ok":1,"cdp_ok":1,"strict_single_chat":1,"tab_count":1,"target_chat_url":"$URL","work_chat_url":"$URL","last_protocol_event":{},"pending_details":{"pending_unacked":1},"ledger_last":{}}
}
EOF
      ;;
    waiting)
      cat >"$STATUS_JSON" <<EOF
{
  "schema_version":"status.v1",
  "ts":$NOW_TS,
  "status":"degraded",
  "can_send":1,
  "blockers":[],
  "warnings":["ledger_pending"],
  "next_actions":["Есть незавершенный цикл SEND->REPLY; сначала проверьте ответ/состояние чата."],
  "operator_summary":{"state":"WAITING","why":"pending_cycle","next":"STEP_WAIT_FINISHED","note":"wait previous cycle","confidence":"med"},
  "multi_tabs":{"present":false,"tab_count":1,"severity":"none","reason":"","hint":""},
  "checkpoint":{"chat_url":"$URL","checkpoint_id":"$CKPT","fingerprint_v1":"$FP"},
  "latest_run":{"exists":1,"run_dir":"","run_id":"run-x","summary_exists":1,"manifest_exists":1,"evidence_dir":"","reason":"E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE","outcome":"pending","exit_status":0,"ts_end":null},
  "ops":{"chat_route_ok":1,"cdp_ok":1,"strict_single_chat":1,"tab_count":1,"target_chat_url":"$URL","work_chat_url":"$URL","last_protocol_event":{},"pending_details":{"pending_unacked":0},"ledger_last":{"state":"pending"}}
}
EOF
      ;;
    cdp_error)
      cat >"$STATUS_JSON" <<EOF
{
  "schema_version":"status.v1",
  "ts":$NOW_TS,
  "status":"blocked",
  "can_send":0,
  "blockers":["cdp_down"],
  "warnings":[],
  "next_actions":["Поднимите браузер (--open-browser) или выполните --graceful-restart-browser."],
  "operator_summary":{"state":"ERROR","why":"cdp_unreachable","next":"RUN_EXPLAIN","note":"cdp down","confidence":"low"},
  "multi_tabs":{"present":false,"tab_count":0,"severity":"none","reason":"","hint":""},
  "checkpoint":{"chat_url":"$URL","checkpoint_id":"$CKPT","fingerprint_v1":"$FP"},
  "latest_run":{"exists":0,"run_dir":"","run_id":"","summary_exists":0,"manifest_exists":0,"evidence_dir":"","reason":"","outcome":"","exit_status":0,"ts_end":null},
  "ops":{"chat_route_ok":0,"cdp_ok":0,"strict_single_chat":1,"tab_count":0,"target_chat_url":"$URL","work_chat_url":"$URL","last_protocol_event":{},"pending_details":{"pending_unacked":0},"ledger_last":{}}
}
EOF
      ;;
    *)
      echo "unknown scenario: $scenario" >&2
      return 1
      ;;
  esac
}

export ROOT
export RUN_ID="run-test-plugin-loop"
export CHATGPT_SEND_TRANSPORT="mock"
export STEP_MAX_STEPS="1"

# shellcheck source=/dev/null
source "$COMMANDS_SH"

rm -f "$TOKEN_JSON"

write_status_fixture ready
chatgpt_send_step_emit_plan "$STATUS_JSON" read "" >"$tmp/step_ready.json"
chatgpt_send_step_emit_plan "$STATUS_JSON" auto "hello" >"$tmp/step_auto_stale.json"

write_status_fixture ack_blocked
chatgpt_send_step_emit_plan "$STATUS_JSON" read "" >"$tmp/step_ack.json"

write_status_fixture waiting
chatgpt_send_step_emit_plan "$STATUS_JSON" read "" >"$tmp/step_wait.json"

write_status_fixture cdp_error
chatgpt_send_step_emit_plan "$STATUS_JSON" read "" >"$tmp/step_err.json"

EXPLAIN_TARGET="E_PREFLIGHT_STALE" OUTPUT_JSON=1 chatgpt_send_explain_command >"$tmp/explain_pref.json"
EXPLAIN_TARGET="E_CDP_UNREACHABLE" OUTPUT_JSON=1 chatgpt_send_explain_command >"$tmp/explain_cdp.json"

python3 - "$tmp" <<'PY'
import json
import pathlib
import sys

tmp = pathlib.Path(sys.argv[1])

ALLOWED_STATES = {"READY", "WAITING", "RECOVERABLE", "BLOCKED", "ERROR"}
ALLOWED_CONF = {"high", "med", "low"}
ALLOWED_NEXT = {
    "ACK",
    "RUN_STATUS",
    "RUN_EXPLAIN",
    "STEP_READ",
    "STEP_PREFLIGHT",
    "STEP_WAIT_FINISHED",
    "STEP_RECOVER",
    "DELEGATE_SEND_PIPELINE",
    "ABORT_SAFE",
}

def load(name):
    with open(tmp / name, encoding="utf-8") as f:
        return json.load(f)

def assert_operator_summary(obj, name):
    os = obj.get("operator_summary")
    assert isinstance(os, dict), (name, "missing operator_summary")
    for key in ("state", "why", "next", "note", "confidence"):
        assert key in os, (name, "missing", key)
        assert isinstance(os[key], str), (name, key, type(os[key]).__name__)
        assert os[key] != "", (name, key, "empty")
    assert os["state"] in ALLOWED_STATES, (name, os["state"])
    assert os["confidence"] in ALLOWED_CONF, (name, os["confidence"])
    assert os["next"] in ALLOWED_NEXT, (name, os["next"])
    return os

def action_to_cli(action_id, has_message=False):
    if action_id == "ACK":
        return "chatgpt_send --ack"
    if action_id == "RUN_STATUS":
        return "chatgpt_send --status --json"
    if action_id == "RUN_EXPLAIN":
        return "chatgpt_send --explain latest --json"
    if action_id in ("STEP_READ", "STEP_PREFLIGHT"):
        return "chatgpt_send step read --json"
    if action_id == "STEP_WAIT_FINISHED":
        return "chatgpt_send step auto --max-steps 1"
    if action_id == "STEP_RECOVER":
        return "chatgpt_send step auto --max-steps 1"
    if action_id == "DELEGATE_SEND_PIPELINE":
        assert has_message, "send action requires message"
        return "chatgpt_send step send --message '...'"
    if action_id == "ABORT_SAFE":
        return "STOP"
    raise AssertionError(("unexpected action_id", action_id))

def canonical_loop_decision(status_obj, step_obj=None, has_message=False):
    s = assert_operator_summary(status_obj, "status")
    if s["state"] == "READY":
        if s["next"] == "STEP_READ":
            assert step_obj is not None, "READY path expects step read"
            step_os = assert_operator_summary(step_obj, "step")
            dec_next = (((step_obj.get("decision") or {}).get("next") or {}).get("action_id"))
            assert step_os["next"] == dec_next, ("step operator_summary mismatch", step_os["next"], dec_next)
            return action_to_cli(step_os["next"], has_message=has_message)
        return action_to_cli(s["next"], has_message=has_message)
    if s["state"] == "WAITING":
        return action_to_cli(s["next"])
    if s["state"] in ("RECOVERABLE", "BLOCKED", "ERROR"):
        # External agent can inspect step if available, otherwise follow status and then explain.
        return action_to_cli(s["next"])
    raise AssertionError(("unknown state", s["state"]))

status_ready = load("root/state/status/status.v1.json") if False else None

step_ready = load("step_ready.json")
step_auto_stale = load("step_auto_stale.json")
step_ack = load("step_ack.json")
step_wait = load("step_wait.json")
step_err = load("step_err.json")
exp_pref = load("explain_pref.json")
exp_cdp = load("explain_cdp.json")

for name, obj in [
    ("step_ready", step_ready),
    ("step_auto_stale", step_auto_stale),
    ("step_ack", step_ack),
    ("step_wait", step_wait),
    ("step_err", step_err),
    ("explain_pref", exp_pref),
    ("explain_cdp", exp_cdp),
]:
    assert_operator_summary(obj, name)

for name, step in [
    ("step_ready", step_ready),
    ("step_auto_stale", step_auto_stale),
    ("step_ack", step_ack),
    ("step_wait", step_wait),
    ("step_err", step_err),
]:
    os = step["operator_summary"]
    dec_next = (((step.get("decision") or {}).get("next") or {}).get("action_id"))
    assert os["next"] == dec_next, (name, os["next"], dec_next)

# Scenario fixtures (status JSONs) are re-created inline so we can validate consumer loop from status->step.
scenarios = [
    ("ready", {
        "operator_summary":{"state":"READY","why":"ok_ready","next":"STEP_READ","note":"ready","confidence":"high"}
    }, step_ready, False, "chatgpt_send step read --json"),
    ("ack_blocked", {
        "operator_summary":{"state":"BLOCKED","why":"ack_required","next":"ACK","note":"ack first","confidence":"high"}
    }, step_ack, False, "chatgpt_send --ack"),
    ("waiting", {
        "operator_summary":{"state":"WAITING","why":"pending_cycle","next":"STEP_WAIT_FINISHED","note":"wait","confidence":"med"}
    }, step_wait, False, "chatgpt_send step auto --max-steps 1"),
    ("cdp_error", {
        "operator_summary":{"state":"ERROR","why":"cdp_unreachable","next":"RUN_EXPLAIN","note":"cdp down","confidence":"low"}
    }, step_err, False, "chatgpt_send --explain latest --json"),
]

for name, status_stub, step_obj, has_message, want in scenarios:
    got = canonical_loop_decision(status_stub, step_obj=step_obj, has_message=has_message)
    assert got == want, (name, got, want)

# Stale preflight path: step(auto,message) must block delegated send and point back to STEP_PREFLIGHT.
os_auto = step_auto_stale["operator_summary"]
assert os_auto["state"] == "RECOVERABLE", os_auto
assert os_auto["why"] == "stale_preflight", os_auto
assert os_auto["next"] == "STEP_PREFLIGHT", os_auto
assert ((step_auto_stale.get("block") or {}).get("error_code")) == "E_PREFLIGHT_STALE", step_auto_stale.get("block")

# explain contract samples should be actionable
assert exp_pref["operator_summary"]["state"] in ("RECOVERABLE", "BLOCKED")
assert exp_pref["operator_summary"]["next"] in ALLOWED_NEXT
assert exp_cdp["operator_summary"]["state"] in ("ERROR", "BLOCKED")
assert exp_cdp["operator_summary"]["next"] in ALLOWED_NEXT
PY

echo "OK"
