#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN_FILE="$ROOT/bin/spawn_second_agent"
SEND_FILE="$ROOT/bin/chatgpt_send"

fails=0

fail_rule() {
  local rule="$1"
  local file="$2"
  local detail="$3"
  echo "PROMPT_LINT_FAIL rule=${rule} file=${file} detail=${detail}"
  fails=$((fails+1))
}

require_token() {
  local file="$1"
  local token="$2"
  local rule="$3"
  if ! rg -q --fixed-strings -- "$token" "$file"; then
    fail_rule "$rule" "$file" "missing_token=${token}"
  fi
}

forbid_pattern_in_text() {
  local text_file="$1"
  local pattern="$2"
  local rule="$3"
  local hit
  hit="$(rg -n -m 1 -- "$pattern" "$text_file" || true)"
  if [[ -n "${hit:-}" ]]; then
    fail_rule "$rule" "$text_file" "$(echo "$hit" | head -n 1)"
  fi
}

if [[ ! -f "$SPAWN_FILE" ]]; then
  fail_rule "spawn_exists" "$SPAWN_FILE" "missing_file"
fi
if [[ ! -f "$SEND_FILE" ]]; then
  fail_rule "send_exists" "$SEND_FILE" "missing_file"
fi

# MUST INCLUDE: spawn entrypoint markers.
require_token "$SPAWN_FILE" "FLOW_OK phase=" "spawn_flow_ok"
require_token "$SPAWN_FILE" "ITER_STATUS step=" "spawn_iter_status"
require_token "$SPAWN_FILE" "--chatgpt-url" "spawn_explicit_chat_url"
require_token "$SPAWN_FILE" "CHATGPT_SEND_FORCE_CHAT_URL" "spawn_force_chat_env"
require_token "$SPAWN_FILE" "CHILD_RESULT:" "spawn_child_result_marker"

# MUST INCLUDE: send-side safety markers.
require_token "$SEND_FILE" "WORK_CHAT url=" "send_work_chat_banner"
require_token "$SEND_FILE" "E_SEND_WITHOUT_PRECHECK" "send_precheck_enforced"
require_token "$SEND_FILE" "E_REPLY_UNACKED_BLOCK_SEND" "send_unacked_block"
require_token "$SEND_FILE" "ACK_WRITE" "send_ack_marker"

# Extract only child prompt template text from spawn file for must-not checks.
spawn_prompt_tmp="$(mktemp)"
trap 'rm -f "$spawn_prompt_tmp"' EXIT
awk '
  /cat >"\$prompt_file" <<EOF/ {in_block=1; next}
  in_block && /^EOF$/ {in_block=0; exit}
  in_block {print}
' "$SPAWN_FILE" >"$spawn_prompt_tmp"

# MUST NOT: risky guidance in prompt template.
forbid_pattern_in_text "$spawn_prompt_tmp" "https://chatgpt.com/" "spawn_prompt_no_home_url"
forbid_pattern_in_text "$spawn_prompt_tmp" "resend|send again|try again" "spawn_prompt_no_resend_words"
forbid_pattern_in_text "$spawn_prompt_tmp" "Reusing active Specialist chat" "spawn_prompt_no_active_reuse"
forbid_pattern_in_text "$SEND_FILE" "CHATGPT_SEND_HOME_REUSES_ACTIVE:-1" "send_home_reuse_default_must_be_off"

echo "PROMPT_LINT_FAILS=${fails}"
if [[ "$fails" -ne 0 ]]; then
  exit 1
fi
echo "PROMPT_LINT_OK=1"
