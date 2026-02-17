#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID=""
WITH_SOAK_SHORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-soak-short)
      WITH_SOAK_SHORT=1
      shift
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    *)
      if [[ -z "${RUN_ID:-}" ]]; then
        RUN_ID="$1"
        shift
      else
        echo "Unknown arg: $1" >&2
        exit 2
      fi
      ;;
  esac
done
if [[ -z "${RUN_ID//[[:space:]]/}" ]]; then
  RUN_ID="gate-$(date +%s)-$RANDOM"
fi
RUN_DIR="$ROOT/state/runs/$RUN_ID"
TEST_DIR="$RUN_DIR/tests"
SUMMARY_FILE="$RUN_DIR/summary.txt"
CHECK_LOG="$RUN_DIR/gate_check.log"
DOCTOR_JSONL="$RUN_DIR/doctor.jsonl"
RUNTIME_ROOT="$RUN_DIR/runtime_root"
RUN_ONE_STATUS=0

mkdir -p "$TEST_DIR"
# Isolate chat/session state for gate runs so tests never rewrite the operator's
# active Specialist chat metadata.
mkdir -p "$RUNTIME_ROOT/state"
ln -sfn "$ROOT/bin" "$RUNTIME_ROOT/bin"
ln -sfn "$ROOT/docs" "$RUNTIME_ROOT/docs"
export CHATGPT_SEND_ROOT="$RUNTIME_ROOT"
# Keep shared logged-in browser profile to avoid re-login in live tests.
export CHATGPT_SEND_PROFILE_DIR="${CHATGPT_SEND_PROFILE_DIR:-$ROOT/state/manual-login-profile}"
export CHATGPT_SEND_RUN_ID="$RUN_ID"
export CHATGPT_SEND_LOG_DIR="$RUN_DIR"

echo "RUN_ID=$RUN_ID" | tee "$SUMMARY_FILE"
echo "RUN_DIR=$RUN_DIR" | tee -a "$SUMMARY_FILE"
echo "RUNTIME_ROOT=$RUNTIME_ROOT" | tee -a "$SUMMARY_FILE"
echo "DOCTOR_JSONL=$DOCTOR_JSONL" | tee -a "$SUMMARY_FILE"

set +e
"$ROOT/bin/chatgpt_send" --doctor --json >"$DOCTOR_JSONL" 2>>"$SUMMARY_FILE"
doctor_st=$?
set -e
echo "doctor_status=$doctor_st" | tee -a "$SUMMARY_FILE"
if [[ "$doctor_st" -ne 0 ]]; then
  echo "doctor failed" | tee -a "$SUMMARY_FILE"
  exit 1
fi

run_one() {
  local name="$1"
  local cmd="$2"
  local log="$TEST_DIR/${name}.log"
  local st=0
  echo "== TEST $name ==" | tee -a "$SUMMARY_FILE"
  set +e
  (cd "$ROOT" && bash -lc "$cmd") >"$log" 2>&1
  st=$?
  set -e
  RUN_ONE_STATUS="$st"
  echo "status=$st log=$log" | tee -a "$SUMMARY_FILE"
  return $st
}

failed=0
skipped=0

run_one "test_cli" "bash test/test_cli.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_wait_only_blocks_send" "bash test/test_wait_only_blocks_send.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_cleanup_idempotent" "bash test/test_cleanup_idempotent.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_doctor_invariants" "bash test/test_doctor_invariants.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_run_manifest_summary" "bash test/test_run_manifest_summary.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_restart_not_allowed_by_default" "bash test/test_restart_not_allowed_by_default.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_graceful_restart_preserves_work_chat" "bash test/test_graceful_restart_preserves_work_chat.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_timeout_budget_fails_when_restart_not_allowed" "bash test/test_timeout_budget_fails_when_restart_not_allowed.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_timeout_budget_triggers_restart_in_soak" "bash test/test_timeout_budget_triggers_restart_in_soak.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_prompt_lint" "bash test/test_prompt_lint.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_ui_contract_probe" "bash test/test_ui_contract_probe.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_evidence_bundle_on_timeout" "bash test/test_evidence_bundle_on_timeout.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_evidence_sanitizer" "bash test/test_evidence_sanitizer.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_ack_blocks_send" "bash test/test_ack_blocks_send.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_ack_allows_next_send" "bash test/test_ack_allows_next_send.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_duplicate_prompt_blocked" "bash test/test_duplicate_prompt_blocked.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_set_chatgpt_url_protect_mismatch" "bash test/test_set_chatgpt_url_protect_mismatch.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_strict_single_chat_block" "bash test/test_strict_single_chat_block.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_work_chat_url_priority" "bash test/test_work_chat_url_priority.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_target_chat_guard" "bash test/test_target_chat_guard.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_no_send_without_precheck" "bash test/test_no_send_without_precheck.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_auto_wait_on_generation" "bash test/test_auto_wait_on_generation.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_reply_wait_polling" "bash test/test_reply_wait_polling.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_soft_reset_runtime_eval_timeout" "bash test/test_soft_reset_runtime_eval_timeout.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_spawn_second_agent" "bash test/test_spawn_second_agent.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_shared_browser_slots" "bash test/test_shared_browser_slots.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_cdp_chatgpt_wait" "bash test/test_cdp_chatgpt_wait.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_assistant_stability_guard" "bash test/test_assistant_stability_guard.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_echo_miss_recover_no_resend" "bash test/test_echo_miss_recover_no_resend.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_echo_miss_recover_soft_reset_probe_reuse" "bash test/test_echo_miss_recover_soft_reset_probe_reuse.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_resend_idempotency_skips_when_reply_tracked" "bash test/test_resend_idempotency_skips_when_reply_tracked.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_cdp_chatgpt_stale_guard" "bash test/test_cdp_chatgpt_stale_guard.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_home_probe_no_active_switch" "bash scripts/test_profile_wrap.sh --run-id '${RUN_ID}-homeprobe' -- bash test/test_home_probe_no_active_switch.sh '$TEST_DIR/T_e2e_home_probe_no_active_switch.log'" || true
if [[ "$RUN_ONE_STATUS" -eq 2 ]]; then
  skipped=$((skipped+1))
elif [[ "$RUN_ONE_STATUS" -ne 0 ]]; then
  failed=$((failed+1))
fi

if [[ "$WITH_SOAK_SHORT" -eq 1 ]]; then
  run_one "test_soak_short" "bash scripts/test_profile_wrap.sh --run-id '${RUN_ID}-soakshort' -- bash test/test_soak_short.sh" || true
  [[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))
else
  echo "== TEST test_soak_short == skipped (enable with --with-soak-short)" | tee -a "$SUMMARY_FILE"
fi

run_one "test_chaos_kill_chrome" "CHATGPT_SEND_RUN_LIVE_CHAOS=1 bash scripts/test_profile_wrap.sh --run-id '${RUN_ID}-chaos' -- bash test/test_chaos_kill_chrome.sh '$TEST_DIR/T_chaos_kill_chrome.log'" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

set +e
"$ROOT/scripts/release_gate_check.sh" "$RUN_ID" >"$CHECK_LOG" 2>&1
check_st=$?
set -e

cat "$CHECK_LOG" | tee -a "$SUMMARY_FILE"
echo "tests_failed=$failed" | tee -a "$SUMMARY_FILE"
echo "tests_skipped=$skipped" | tee -a "$SUMMARY_FILE"
echo "check_status=$check_st" | tee -a "$SUMMARY_FILE"

if [[ "$failed" -ne 0 ]] || [[ "$check_st" -ne 0 ]]; then
  exit 1
fi
exit 0
