#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${1:-gate-$(date +%s)-$RANDOM}"
RUN_DIR="$ROOT/state/runs/$RUN_ID"
TEST_DIR="$RUN_DIR/tests"
SUMMARY_FILE="$RUN_DIR/summary.txt"
CHECK_LOG="$RUN_DIR/gate_check.log"
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

run_one "test_target_chat_guard" "bash test/test_target_chat_guard.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_no_send_without_precheck" "bash test/test_no_send_without_precheck.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_auto_wait_on_generation" "bash test/test_auto_wait_on_generation.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_reply_wait_polling" "bash test/test_reply_wait_polling.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_spawn_second_agent" "bash test/test_spawn_second_agent.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_shared_browser_slots" "bash test/test_shared_browser_slots.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_cdp_chatgpt_wait" "bash test/test_cdp_chatgpt_wait.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_cdp_chatgpt_stale_guard" "bash test/test_cdp_chatgpt_stale_guard.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_home_probe_no_active_switch" "bash test/test_home_probe_no_active_switch.sh '$TEST_DIR/T_e2e_home_probe_no_active_switch.log'" || true
if [[ "$RUN_ONE_STATUS" -eq 2 ]]; then
  skipped=$((skipped+1))
elif [[ "$RUN_ONE_STATUS" -ne 0 ]]; then
  failed=$((failed+1))
fi

run_one "test_soak_short" "bash test/test_soak_short.sh" || true
[[ "$RUN_ONE_STATUS" -ne 0 ]] && failed=$((failed+1))

run_one "test_chaos_kill_chrome" "CHATGPT_SEND_RUN_LIVE_CHAOS=1 bash test/test_chaos_kill_chrome.sh '$TEST_DIR/T_chaos_kill_chrome.log'" || true
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
