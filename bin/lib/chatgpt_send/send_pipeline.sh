# shellcheck shell=bash
# Send pipeline: target resolution, guards, send, wait, recovery.
chatgpt_send_run_send_pipeline() {
# Resolve WORK_CHAT_URL with a single source-of-truth priority:
# force env -> state/work_chat_url.txt -> explicit arg.
# Legacy fallback: pinned/default env only when work state is absent.
WORK_CHAT_URL=""
CHAT_URL_SOURCE="unset"
work_url="$(read_work_chat_url || true)"
legacy_pinned=""
if [[ -f "$CHATGPT_URL_FILE" ]]; then
  legacy_pinned="$(cat "$CHATGPT_URL_FILE" | head -n 1 || true)"
fi

if [[ -n "${CHATGPT_SEND_FORCE_CHAT_URL:-}" ]]; then
  if is_chat_conversation_url "${CHATGPT_SEND_FORCE_CHAT_URL}"; then
    WORK_CHAT_URL="${CHATGPT_SEND_FORCE_CHAT_URL}"
    CHAT_URL_SOURCE="force_env"
  else
    echo "Warning: ignoring invalid CHATGPT_SEND_FORCE_CHAT_URL: ${CHATGPT_SEND_FORCE_CHAT_URL}" >&2
  fi
fi

if [[ -z "${WORK_CHAT_URL:-}" ]] && [[ $CHATGPT_URL_EXPLICIT -eq 1 ]] && [[ -n "${CHATGPT_URL:-}" ]]; then
  WORK_CHAT_URL="$CHATGPT_URL"
  CHAT_URL_SOURCE="explicit_arg"
fi

if [[ -z "${WORK_CHAT_URL:-}" ]] && [[ -n "${work_url:-}" ]]; then
  WORK_CHAT_URL="$work_url"
  CHAT_URL_SOURCE="work_state"
fi

if [[ -z "${WORK_CHAT_URL:-}" ]] && [[ -n "${legacy_pinned:-}" ]]; then
  WORK_CHAT_URL="$legacy_pinned"
  CHAT_URL_SOURCE="legacy_pinned"
fi

if [[ -z "${WORK_CHAT_URL:-}" ]] && [[ -n "${CHATGPT_URL_DEFAULT:-}" ]]; then
  WORK_CHAT_URL="$CHATGPT_URL_DEFAULT"
  CHAT_URL_SOURCE="default_env"
fi

if [[ -n "${WORK_CHAT_URL:-}" ]]; then
  CHATGPT_URL="$WORK_CHAT_URL"
  if is_chat_conversation_url "$WORK_CHAT_URL"; then
    write_work_chat_url "$WORK_CHAT_URL"
  fi
fi

if [[ $OPEN_BROWSER -eq 1 ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "open_browser"
  fi
  url="${CHATGPT_URL:-https://chatgpt.com/}"
  open_browser_impl "$url" || exit 1
  exit 0
fi

if [[ $SYNC_URL -eq 1 ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "sync_chat_url"
  fi
  if ! cdp_is_up; then
    echo "CDP is not reachable on 127.0.0.1:$CDP_PORT. Run open-browser first." >&2
    exit 2
  fi
  tab="$(capture_best_chat_tab_from_cdp || true)"
  detected="${tab%%$'\t'*}"
  title="${tab#*$'\t'}"
  if [[ -z "${detected:-}" ]] || [[ "$detected" == "$tab" ]]; then
    echo "Could not detect any https://chatgpt.com/c/... tab." >&2
    exit 3
  fi
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && is_chat_conversation_url "${PROTECT_CHAT_URL}" \
    && [[ "$detected" != "${PROTECT_CHAT_URL}" ]]; then
    emit_protect_chat_mismatch "${PROTECT_CHAT_URL}" "$detected"
  fi
  mkdir -p "$(dirname "$CHATGPT_URL_FILE")" >/dev/null 2>&1 || true
  printf '%s\n' "$detected" >"$CHATGPT_URL_FILE"
  write_work_chat_url "$detected"
  chats_db_upsert "last" "$detected" "${title:-}" >/dev/null 2>&1 || true
  existing="$(chats_db_find_name_by_url "$detected" | head -n 1 || true)"
  if [[ -z "${existing:-}" ]] || [[ "$existing" == "last" ]]; then
    name="$(autoname)"
    chats_db_upsert "$name" "$detected" "${title:-}" >/dev/null 2>&1 || true
    chats_db_set_active "$name" >/dev/null 2>&1 || true
  else
    chats_db_set_active "$existing" >/dev/null 2>&1 || true
  fi
  echo "Synced default ChatGPT URL: $detected" >&2
  exit 0
fi

# If a pinned URL exists but it's an invalid conversation URL, ignore it for sending.
if [[ -n "${CHATGPT_URL:-}" ]] && [[ "$CHATGPT_URL" =~ ^https://chatgpt\.com/c/ ]] && ! is_chat_conversation_url "$CHATGPT_URL"; then
  echo "Warning: ignoring invalid pinned chat URL: $CHATGPT_URL" >&2
  CHATGPT_URL=""
fi

if [[ -n "${SAVE_CHAT_NAME//[[:space:]]/}" ]]; then
  if [[ -z "${CHATGPT_URL:-}" ]] && cdp_is_up; then
    tab="$(capture_chat_tab_from_cdp || true)"
    CHATGPT_URL="${tab%%$'\t'*}"
    title="${tab#*$'\t'}"
  fi
  if [[ -z "${CHATGPT_URL:-}" ]]; then
    echo "No chat URL to save. Provide --chatgpt-url, pin one via --set-chatgpt-url, or open browser and keep a single chat tab open." >&2
    exit 2
  fi
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && is_chat_conversation_url "${PROTECT_CHAT_URL}" \
    && is_chat_conversation_url "${CHATGPT_URL}" && [[ "${CHATGPT_URL}" != "${PROTECT_CHAT_URL}" ]]; then
    emit_protect_chat_mismatch "${PROTECT_CHAT_URL}" "${CHATGPT_URL}"
  fi
  chats_db_upsert "$SAVE_CHAT_NAME" "$CHATGPT_URL" "${title:-}" >/dev/null 2>&1 || true
  chats_db_set_active "$SAVE_CHAT_NAME" >/dev/null 2>&1 || true
  printf '%s\n' "$CHATGPT_URL" >"$CHATGPT_URL_FILE" 2>/dev/null || true
  write_work_chat_url "$CHATGPT_URL"
  echo "Saved chat as: $SAVE_CHAT_NAME" >&2
  exit 0
fi

if [[ $DO_ACK -eq 1 ]]; then
  if ! is_chat_conversation_url "${CHATGPT_URL:-}"; then
    emit_target_chat_required "${CHATGPT_URL:-none}"
  fi
  ack_chat_id="$(chat_id_from_url "${CHATGPT_URL:-}" 2>/dev/null || true)"
  if [[ -z "${ack_chat_id:-}" ]]; then
    emit_target_chat_required "${CHATGPT_URL:-none}"
  fi
  ack_fields="$(ack_db_get_fields "$ack_chat_id" || true)"
  IFS=$'\x1f' read -r ack_last_fp ack_consumed_fp ack_last_prompt_hash ack_last_anchor <<<"$ack_fields"
  ack_target_fp="${ack_last_fp:-}"
  ack_db_mark_consumed "$ack_chat_id" "$ack_target_fp"
  echo "ACK_WRITE chat_id=${ack_chat_id} reply_fingerprint=${ack_target_fp:-none} consumed_prev=${ack_consumed_fp:-none} run_id=${RUN_ID}" >&2
  exit 0
fi

EXPLICIT_HOME_PROBE=0
if [[ $CHATGPT_URL_EXPLICIT -eq 1 ]] && [[ "${CHATGPT_URL:-}" == "https://chatgpt.com/" || "${CHATGPT_URL:-}" == "https://chatgpt.com" ]]; then
  EXPLICIT_HOME_PROBE=1
fi
OLD_ACTIVE_NAME="$(chats_db_get_active_name | head -n 1 || true)"
OLD_ACTIVE_URL="$(chats_db_get_active_url | head -n 1 || true)"
if [[ $PRINT_URL -eq 1 ]]; then
  echo "[P2] explicit_home_probe=${EXPLICIT_HOME_PROBE} active_before=${OLD_ACTIVE_NAME:-"(none)"} active_url_before=${OLD_ACTIVE_URL:-"(none)"}" >&2
fi

if [[ -n "$PROMPT_FILE" ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "prompt_file_send"
  fi
  PROMPT="$(cat "$PROMPT_FILE")"
fi

if [[ "${WAIT_ONLY}" == "1" ]] && [[ -n "${PROMPT//[[:space:]]/}" ]]; then
  emit_wait_only_block "prompt_send"
fi

if [[ -z "${PROMPT//[[:space:]]/}" ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "stdin_send"
  fi
  if [[ -t 0 ]]; then
    echo "Missing prompt. Provide --prompt/--prompt-file or pipe via stdin." >&2
    exit 2
  fi
  PROMPT="$(cat)"
fi

if [[ -z "${PROMPT//[[:space:]]/}" ]]; then
  echo "Prompt is empty" >&2
  exit 2
fi

if [[ "${ENFORCE_ITERATION_PREFIX:-1}" == "1" ]]; then
  prompt_iter_fields="$(printf '%s' "$PROMPT" | extract_prompt_iteration_prefix | head -n 1 || true)"
  if [[ -n "${prompt_iter_fields:-}" ]]; then
    read -r prompt_iter prompt_max <<<"${prompt_iter_fields}"
    loop_fields="$(chats_db_loop_expected_iteration | head -n 1 || true)"
    if [[ -n "${loop_fields:-}" ]]; then
      read -r expected_iter expected_max loop_done <<<"${loop_fields}"
      if [[ "${prompt_iter:-}" != "${expected_iter:-}" ]] || [[ "${prompt_max:-}" != "${expected_max:-}" ]]; then
        echo "E_ITERATION_PREFIX_MISMATCH prompt_iter=${prompt_iter:-none}/${prompt_max:-none} expected_iter=${expected_iter:-none}/${expected_max:-none} loop_done=${loop_done:-none} run_id=${RUN_ID}" >&2
        exit 82
      fi
      echo "ITERATION_PREFIX_OK prompt_iter=${prompt_iter}/${prompt_max} expected_iter=${expected_iter}/${expected_max} loop_done=${loop_done} run_id=${RUN_ID}" >&2
    else
      echo "W_ITERATION_PREFIX_LOOP_UNSET prompt_iter=${prompt_iter:-none}/${prompt_max:-none} run_id=${RUN_ID}" >&2
    fi
  fi
fi

PROMPT_SIG="$(text_signature "$PROMPT")"
echo "PROMPT_META prompt_sig=${PROMPT_SIG:-none} norm_version=${NORM_VERSION:-v1} run_id=${RUN_ID}" >&2

echo "PROFILE_DIR path=${PROFILE_DIR} run_id=${RUN_ID}" >&2

# If no explicit/default chat URL is configured, try to auto-capture it from the
# already-open shared Chrome instance. This enables the UX:
# "open browser" -> user creates chat -> first send auto-pins that chat.
if [[ -z "$CHATGPT_URL" ]] && cdp_is_up; then
  tab="$(capture_chat_tab_from_cdp || true)"
  detected="${tab%%$'\t'*}"
  title="${tab#*$'\t'}"
  if [[ -n "${detected:-}" ]] && [[ "$detected" != "$tab" ]]; then
    CHATGPT_URL="$detected"
    CHAT_URL_SOURCE="auto_capture"
    mkdir -p "$(dirname "$CHATGPT_URL_FILE")" >/dev/null 2>&1 || true
    printf '%s\n' "$CHATGPT_URL" >"$CHATGPT_URL_FILE"
    write_work_chat_url "$CHATGPT_URL"
    chats_db_upsert "last" "$CHATGPT_URL" "${title:-}" >/dev/null 2>&1 || true
    existing="$(chats_db_find_name_by_url "$CHATGPT_URL" | head -n 1 || true)"
    if [[ "${EXPLICIT_HOME_PROBE}" == "1" ]]; then
      echo "[P2] active_update=skipped reason=explicit_home_probe old_active=${OLD_ACTIVE_URL:-"(none)"} new_candidate=${CHATGPT_URL}" >&2
    else
      if [[ -z "${existing:-}" ]] || [[ "$existing" == "last" ]]; then
        name="$(autoname)"
        chats_db_upsert "$name" "$CHATGPT_URL" "${title:-}" >/dev/null 2>&1 || true
        chats_db_set_active "$name" >/dev/null 2>&1 || true
      else
        chats_db_set_active "$existing" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

# Hard send guard: prevent "wrong chat" drift by requiring a conversation URL
# and consistent active/pinned metadata before every normal prompt send.
if [[ $INIT_SPECIALIST -eq 0 ]]; then
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && is_chat_conversation_url "${PROTECT_CHAT_URL}"; then
    if [[ "${CHATGPT_URL:-}" != "${PROTECT_CHAT_URL}" ]]; then
      emit_protect_chat_mismatch "${PROTECT_CHAT_URL}" "${CHATGPT_URL:-none}"
    fi
  fi

  pinned_url_current=""
  if [[ -f "$CHATGPT_URL_FILE" ]]; then
    pinned_url_current="$(cat "$CHATGPT_URL_FILE" | head -n 1 || true)"
  fi
  active_url_current="$(chats_db_get_active_url | head -n 1 || true)"

  if [[ "${ENFORCE_ACTIVE_PIN_MATCH}" == "1" ]] \
    && is_chat_conversation_url "${active_url_current:-}" \
    && is_chat_conversation_url "${pinned_url_current:-}" \
    && [[ "${active_url_current}" != "${pinned_url_current}" ]]; then
    emit_chat_state_mismatch "${active_url_current}" "${pinned_url_current}"
  fi

  if [[ "${REQUIRE_CONVO_URL}" == "1" ]]; then
    if is_chat_conversation_url "${CHATGPT_URL:-}"; then
      :
    elif [[ "${ALLOW_HOME_SEND}" == "1" ]] \
      && [[ "${CHATGPT_URL:-}" == "https://chatgpt.com/" || "${CHATGPT_URL:-}" == "https://chatgpt.com" ]]; then
      log_action "target_guard" "result=allow_home_send"
    else
      emit_target_chat_required "${CHATGPT_URL:-none}"
    fi
  fi
fi

WORK_CHAT_ID="$(chat_id_from_url "${CHATGPT_URL:-}" 2>/dev/null || true)"
echo "WORK_CHAT url=${CHATGPT_URL:-none} chat_id=${WORK_CHAT_ID:-none} source=${CHAT_URL_SOURCE:-unknown} strict_single_chat=${STRICT_SINGLE_CHAT} run_id=${RUN_ID}" >&2

set +e
acquire_chat_single_flight_lock "${CHATGPT_URL:-}"
chat_lock_st=$?
set -e
if [[ $chat_lock_st -ne 0 ]]; then
  RUN_OUTCOME="chat_single_flight_lock_failed"
  exit "$chat_lock_st"
fi

PROMPT_HASH="$(printf '%s' "$PROMPT" | stable_hash)"
LEDGER_LOOKUP_KEY="$(ledger_key_for "${CHATGPT_URL:-}" "${PROMPT_HASH:-}" | head -n 1 || true)"
ACK_CHAT_ID="$(chat_id_from_url "${CHATGPT_URL:-}" 2>/dev/null || true)"
ACK_LAST_REPLY_FP=""
ACK_LAST_CONSUMED_FP=""
ACK_LAST_PROMPT_HASH=""
ACK_LAST_ANCHOR_ID=""
ACK_PENDING_UNACKED=0
if [[ -n "${ACK_CHAT_ID:-}" ]]; then
  ack_fields="$(ack_db_get_fields "$ACK_CHAT_ID" || true)"
  IFS=$'\x1f' read -r ACK_LAST_REPLY_FP ACK_LAST_CONSUMED_FP ACK_LAST_PROMPT_HASH ACK_LAST_ANCHOR_ID <<<"$ack_fields"
  if [[ -n "${ACK_LAST_REPLY_FP:-}" ]] && [[ "${ACK_LAST_REPLY_FP}" != "${ACK_LAST_CONSUMED_FP:-}" ]]; then
    ACK_PENDING_UNACKED=1
  fi
  if [[ "$ACK_PENDING_UNACKED" -eq 1 ]] && [[ "${PROMPT_HASH:-}" != "${ACK_LAST_PROMPT_HASH:-}" ]]; then
    echo "E_REPLY_UNACKED_BLOCK_SEND chat_id=${ACK_CHAT_ID} reply_fingerprint=${ACK_LAST_REPLY_FP} consumed=${ACK_LAST_CONSUMED_FP:-none} run_id=${RUN_ID}" >&2
    capture_evidence_snapshot "E_REPLY_UNACKED_BLOCK_SEND" || true
    echo "ITER_RESULT outcome=BLOCK reason=reply_unacked_block_send send=0 reuse=0 evidence=1 run_id=${RUN_ID}" >&2
    exit 12
  fi
fi

has_convo_url=0
if [[ -n "${CHATGPT_URL:-}" ]] && is_chat_conversation_url "$CHATGPT_URL"; then
  has_convo_url=1
fi

slug="send-$(date +%Y%m%d-%H%M%S)"
if [[ -n "${LOG_DIR:-}" ]]; then
  mkdir -p "${LOG_DIR}/cdp" >/dev/null 2>&1 || true
  out="${LOG_DIR}/cdp/chatgpt_send_${slug}_$$.md"
else
  out="/tmp/chatgpt_send_${slug}_$$.md"
fi

# Ensure we have a visible, shared Chrome to operate against.
# (Do this before we capture pre/post URLs for auto-pinning.)
if ! cdp_is_up; then
  open_browser_impl "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
fi
if ! cdp_is_up; then
  echo "CDP is not reachable on 127.0.0.1:$CDP_PORT. Browser is not ready." >&2
  exit 2
fi

# If no conversation URL is pinned yet, remember current chat tabs; after the
# first send we can pin the newly created conversation URL.
pre_chat_urls=""
if [[ $has_convo_url -eq 0 ]] && cdp_is_up; then
  pre_chat_urls="$(capture_chat_urls_from_cdp | sort -u || true)"
fi

# If we already have a pinned conversation URL and CDP is available, activate it
# before sending so the human can see the message being sent in the same tab.
if [[ $has_convo_url -eq 1 ]] && cdp_is_up; then
  cdp_activate_or_open_url "$CHATGPT_URL" || true
  if [[ "${STRICT_SINGLE_CHAT}" == "1" ]]; then
    ensure_single_chat_target "$CHATGPT_URL" || exit 78
  else
    cdp_cleanup_chat_tabs "$CHATGPT_URL" || true
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run) would send prompt to: ${CHATGPT_URL:-https://chatgpt.com/}" >&2
  echo "(dry-run) prompt bytes: $(printf '%s' "$PROMPT" | wc -c | tr -d ' ')" >&2
  exit 0
fi

if [[ $PRINT_URL -eq 1 ]]; then
  echo "ChatGPT URL: ${CHATGPT_URL:-https://chatgpt.com/}" >&2
fi

timeout_s="$(resolve_timeout_seconds)"
PRECHECK_DONE=0
LEDGER_PROMPT_STATE="none"
FETCH_LAST_JSON=""
FETCH_LAST_CHECKPOINT_ID=""
FETCH_LAST_LAST_USER_HASH=""
FETCH_LAST_ASSISTANT_AFTER_LAST_USER="0"
FETCH_LAST_ASSISTANT_TAIL_HASH=""
FETCH_LAST_USER_TAIL_HASH=""
FETCH_LAST_TOTAL_MESSAGES="0"
FETCH_LAST_STOP_VISIBLE="0"
FETCH_LAST_LAST_USER_SIG=""
FETCH_LAST_LAST_ASSISTANT_SIG=""
FETCH_LAST_CHAT_ID=""
FETCH_LAST_UI_CONTRACT_SIG=""
FETCH_LAST_FINGERPRINT_V1=""
FETCH_LAST_LAST_USER_TEXT_SIG=""
FETCH_LAST_LAST_ASSISTANT_TEXT_SIG=""
FETCH_LAST_UI_STATE=""
FETCH_LAST_NORM_VERSION=""


RUN_SUMMARY_ENABLED=1
RUN_SUMMARY_WRITTEN=0
RUN_STARTED_MS="$(now_ms)"
trap 'run_summary_finalize_on_exit' EXIT
write_run_manifest

if [[ "${STRICT_UI_CONTRACT}" == "1" ]]; then
  log_action "contract_check" "result=start strict=1"
  set +e
  contract_probe_via_cdp
  contract_status=$?
  set -e
  if [[ $contract_status -eq 0 ]]; then
    log_action "contract_check" "result=ok"
  else
    log_action "contract_check" "result=fail status=${contract_status}"
    capture_evidence_snapshot "E_UI_CONTRACT_FAIL"
    echo "chatgpt_send failed (ui contract status=$contract_status)." >&2
    exit "$contract_status"
  fi
fi

echo "RECOVERY_START run_id=${RUN_ID} chat_url=${CHATGPT_URL:-none}" >&2
if ! fetch_last_via_cdp; then
  echo "RECOVERY_DONE fail run_id=${RUN_ID}" >&2
  RUN_OUTCOME="fetch_last_failed"
  if [[ "${FETCH_LAST_REQUIRED}" == "1" ]]; then
    echo "E_FETCH_LAST_FAILED required=1 run_id=${RUN_ID}" >&2
    exit 79
  fi
  echo "W_FETCH_LAST_FAILED required=0 run_id=${RUN_ID}" >&2
else
  echo "RECOVERY_DONE ok run_id=${RUN_ID}" >&2
fi

if [[ -z "${FETCH_LAST_CHECKPOINT_ID:-}" ]]; then
  FETCH_LAST_CHECKPOINT_ID="$(read_last_specialist_checkpoint_id | head -n 1 || true)"
fi

# Hard no-duplicate guard:
# if latest user message already equals this prompt hash, do not resend.
if [[ -n "${FETCH_LAST_LAST_USER_HASH:-}" ]] && [[ -n "${PROMPT_HASH:-}" ]] \
  && [[ "${FETCH_LAST_LAST_USER_HASH}" == "${PROMPT_HASH}" ]] \
  && [[ "${FETCH_LAST_ASSISTANT_AFTER_LAST_USER:-0}" == "1" ]] \
  && { [[ -n "${FETCH_LAST_ASSISTANT_TAIL_HASH:-}" ]] || [[ -n "${FETCH_LAST_LAST_ASSISTANT_SIG:-}" ]]; }; then
  echo "NO_RESEND_PROMPT_ALREADY_PRESENT prompt_hash=${PROMPT_HASH} run_id=${RUN_ID}" >&2
  if [[ -n "${FETCH_LAST_JSON:-}" ]] && fetch_last_reuse_text_for_prompt "$FETCH_LAST_JSON" "${PROMPT_HASH:-}" >"$out"; then
    echo "REUSE_EXISTING reason=prompt_already_present run_id=${RUN_ID}" >&2
    protocol_append_event "REUSE_EXISTING" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=prompt_already_present"
    protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=prompt_already_present"
    record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
    RUN_OUTCOME="reuse_existing_prompt_already_present"
    cat "$out"
    exit 0
  fi
  if [[ "${REPLY_POLLING}" == "1" ]]; then
    set +e
    reply_wait_collect_via_probe
    reply_status=$?
    set -e
    if [[ $reply_status -eq 0 ]]; then
      echo "REUSE_EXISTING reason=prompt_already_present_wait run_id=${RUN_ID}" >&2
      protocol_append_event "REUSE_EXISTING" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=prompt_already_present_wait"
      protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=prompt_already_present_wait"
      record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
      RUN_OUTCOME="reuse_existing_prompt_already_present_wait"
      cat "$out"
      exit 0
    fi
    if [[ $reply_status -eq 2 ]]; then
      protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=prompt_already_present_wait route_mismatch"
      RUN_OUTCOME="prompt_already_present_wait_route_mismatch"
      echo "chatgpt_send failed (prompt-already-present wait route mismatch)." >&2
      exit 2
    fi
    if [[ $reply_status -eq 76 ]]; then
      protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=prompt_already_present_wait timeout"
      RUN_OUTCOME="prompt_already_present_wait_timeout"
      exit 76
    fi
  fi
  echo "E_NO_BLIND_RESEND ledger_state=none reason=prompt_already_present_no_reply run_id=${RUN_ID}" >&2
  protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "reason=no_blind_resend_prompt_already_present"
  capture_evidence_snapshot "E_NO_BLIND_RESEND_PROMPT_ALREADY_PRESENT" || true
  RUN_OUTCOME="no_blind_resend_prompt_already_present"
  exit 14
fi

LEDGER_LAST_EVENT="none"
LEDGER_LAST_TS=""
ledger_info="$(protocol_prompt_state_info "${PROMPT_HASH:-}" "${CHATGPT_URL:-}" | head -n 1 || true)"
IFS=$'\t' read -r LEDGER_PROMPT_STATE LEDGER_LOOKUP_KEY LEDGER_LAST_EVENT LEDGER_LAST_TS <<<"$ledger_info"
[[ -n "${LEDGER_PROMPT_STATE:-}" ]] || LEDGER_PROMPT_STATE="none"
echo "LEDGER_LOOKUP key=${LEDGER_LOOKUP_KEY:-none} result=${LEDGER_PROMPT_STATE} last_event=${LEDGER_LAST_EVENT:-none} last_ts=${LEDGER_LAST_TS:-none} run_id=${RUN_ID}" >&2

pending_auto_heal_reuse() {
  # Usage: pending_auto_heal_reuse <trigger> <refresh_fetch_last:0|1>
  local trigger="${1:-unknown}"
  local refresh_fetch_last="${2:-0}"
  local st
  if [[ "${NO_BLIND_RESEND}" != "1" ]] || [[ "${LEDGER_PROMPT_STATE}" != "pending" ]]; then
    return 1
  fi
  echo "LEDGER_PENDING_AUTO_HEAL start trigger=${trigger} refresh=${refresh_fetch_last} run_id=${RUN_ID}" >&2
  if [[ "${refresh_fetch_last}" == "1" ]]; then
    set +e
    fetch_last_via_cdp
    st=$?
    set -e
    if [[ $st -ne 0 ]]; then
      echo "LEDGER_PENDING_AUTO_HEAL fetch_last_status=${st} trigger=${trigger} run_id=${RUN_ID}" >&2
      return 1
    fi
  fi
  if [[ -n "${FETCH_LAST_JSON:-}" ]] && fetch_last_reuse_text_for_prompt "$FETCH_LAST_JSON" "${PROMPT_HASH:-}" >"$out"; then
    protocol_append_event "REUSE_EXISTING" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=pending_auto_heal trigger=${trigger}"
    protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=pending_auto_heal trigger=${trigger}"
    record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
    RUN_OUTCOME="reuse_existing_pending_auto_heal"
    echo "LEDGER_PENDING_AUTO_HEAL done outcome=ready trigger=${trigger} run_id=${RUN_ID}" >&2
    cat "$out"
    exit 0
  fi
  echo "LEDGER_PENDING_AUTO_HEAL done outcome=still_pending trigger=${trigger} run_id=${RUN_ID}" >&2
  return 1
}

if [[ "${NO_BLIND_RESEND}" == "1" ]] && [[ "${LEDGER_PROMPT_STATE}" == "ready" ]]; then
  if [[ -n "${FETCH_LAST_JSON:-}" ]] && fetch_last_reuse_text_for_prompt "$FETCH_LAST_JSON" "${PROMPT_HASH:-}" >"$out"; then
    echo "REUSE_EXISTING reason=ledger_ready run_id=${RUN_ID}" >&2
    protocol_append_event "REUSE_EXISTING" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=ledger_ready"
    protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=ledger_ready"
    record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
    RUN_OUTCOME="reuse_existing_ledger_ready"
    cat "$out"
    exit 0
  fi
  echo "E_NO_BLIND_RESEND ledger_state=ready reason=no_reusable_reply run_id=${RUN_ID}" >&2
  protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "reason=no_blind_resend_ledger_ready"
  RUN_OUTCOME="no_blind_resend_ledger_ready"
  exit 14
fi

pending_auto_heal_reuse "post_lookup" "0" || true

if [[ "${SKIP_PRECHECK}" == "1" ]]; then
  PRECHECK_DONE=1
  log_action "precheck" "result=skipped debug=1"
  if [[ "${NO_BLIND_RESEND}" == "1" ]] && [[ "${LEDGER_PROMPT_STATE}" == "pending" ]]; then
    pending_auto_heal_reuse "skip_precheck_block" "1" || true
    echo "E_NO_BLIND_RESEND ledger_state=pending reason=send_without_reply run_id=${RUN_ID}" >&2
    protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "reason=no_blind_resend_pending_skip_precheck"
    RUN_OUTCOME="no_blind_resend_pending"
    exit 14
  fi
else
  log_action "precheck" "result=start"
  set +e
  precheck_via_cdp
  precheck_status=$?
  set -e

  if [[ $precheck_status -eq 11 ]] && [[ "${AUTO_WAIT_ON_GENERATION}" != "0" ]]; then
    set +e
    precheck_auto_wait_loop
    precheck_status=$?
    set -e
    if [[ $precheck_status -eq 73 ]]; then
      exit 73
    fi
  fi

  if [[ $precheck_status -eq 0 ]]; then
    PRECHECK_DONE=1
    log_action "reuse" "result=precheck_hit"
    protocol_append_event "REUSE_EXISTING" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=precheck"
    protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "source=precheck"
    record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
    RUN_OUTCOME="reuse_precheck"
    cat "$out"
    exit 0
  fi
  if [[ $precheck_status -eq 10 ]]; then
    PRECHECK_DONE=1
    log_action "precheck" "result=no_new_reply"
    if [[ "${NO_BLIND_RESEND}" == "1" ]] && [[ "${LEDGER_PROMPT_STATE}" == "pending" ]]; then
      pending_auto_heal_reuse "precheck_no_new_reply_block" "1" || true
      echo "E_NO_BLIND_RESEND ledger_state=pending reason=send_without_reply run_id=${RUN_ID}" >&2
      protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "reason=no_blind_resend_pending"
      RUN_OUTCOME="no_blind_resend_pending"
      exit 14
    fi
  elif [[ $precheck_status -eq 11 ]]; then
    PRECHECK_DONE=1
    log_action "precheck" "result=generation_in_progress continue=1"
  elif [[ $precheck_status -eq 2 ]]; then
    RUN_OUTCOME="precheck_route_mismatch"
    echo "chatgpt_send precheck failed (route mismatch)." >&2
    exit 2
  else
    PRECHECK_DONE=1
    log_action "precheck" "result=failed status=${precheck_status} continue=1"
  fi
fi

if [[ "$ACK_PENDING_UNACKED" -eq 1 ]] && [[ -n "${ACK_CHAT_ID:-}" ]] && [[ "${PROMPT_HASH:-}" == "${ACK_LAST_PROMPT_HASH:-}" ]]; then
  echo "E_DUPLICATE_PROMPT_BLOCKED chat_id=${ACK_CHAT_ID} prompt_hash=${PROMPT_HASH} run_id=${RUN_ID}" >&2
  RUN_OUTCOME="duplicate_prompt_blocked"
  exit 13
fi
if [[ -n "${ACK_CHAT_ID:-}" ]] && [[ -n "${PROMPT_HASH:-}" ]]; then
  ack_db_mark_prompt "$ACK_CHAT_ID" "$PROMPT_HASH"
fi

echo "SEND_BASELINE last_user_hash=${FETCH_LAST_LAST_USER_HASH:-none} last_user_sig=${FETCH_LAST_LAST_USER_TEXT_SIG:-none} run_id=${RUN_ID}" >&2
echo "SEND_START prompt_sig=${PROMPT_SIG:-none} prompt_hash=${PROMPT_HASH:-none} ledger_key=${LEDGER_LOOKUP_KEY:-none} norm_version=${NORM_VERSION:-v1} run_id=${RUN_ID}" >&2
dispatch_preferred="${CHATGPT_SEND_DISPATCH_PREFERRED:-enter}"
if [[ "${dispatch_preferred}" != "enter" ]] && [[ "${dispatch_preferred}" != "click" ]] && [[ "${dispatch_preferred}" != "button" ]]; then
  dispatch_preferred="enter"
fi
export CHATGPT_SEND_DISPATCH_PREFERRED="${dispatch_preferred}"
echo "SEND_DISPATCH attempt=1 method=${dispatch_preferred} run_id=${RUN_ID}" >&2
set +e
run_send_checked "initial"
status=$?
set -e

if [[ $status -eq 3 ]] && [[ "${dispatch_preferred}" == "enter" ]]; then
  echo "SEND_DISPATCH attempt=2 method=click run_id=${RUN_ID}" >&2
  export CHATGPT_SEND_DISPATCH_PREFERRED="click"
  set +e
  run_send_checked "retry_dispatch_click"
  status=$?
  set -e
  export CHATGPT_SEND_DISPATCH_PREFERRED="${dispatch_preferred}"
fi

if [[ $status -eq 6 ]]; then
  # Chrome may be running without --remote-allow-origins; restart our automation
  # Chrome instance with the correct flags.
  stale_pids="$(chrome_pids_for_profile | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "${stale_pids//[[:space:]]/}" ]]; then
    echo "Restarting automation Chrome to enable CDP WebSocket access..." >&2
    for p in $stale_pids; do
      kill "$p" 2>/dev/null || true
    done
    sleep 0.8
  fi
  maybe_cdp_recover "status6_websocket_handshake" "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
  set +e
  run_send_checked "retry_status6"
  status=$?
  set -e
fi

if [[ $status -eq 1 ]]; then
  # CDP HTTP endpoint may not be ready immediately after browser launch/focus.
  # Wait briefly and retry once before failing hard.
  echo "CDP connection failed (status=1). Waiting for browser CDP to become ready..." >&2
  if ! wait_for_cdp; then
    maybe_cdp_recover "status1_initial" "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
    wait_for_cdp || true
  fi
  set +e
  run_send_checked "retry_status1"
  status=$?
  set -e
fi

tab_recover_attempted=0
if [[ $status -eq 2 || $status -eq 5 ]]; then
  tab_recover_attempted=1
  # Recover from missing/invalid active target tab or transient CDP disconnects.
  # Keep retries bounded and deterministic.
  recover_try=1
  while [[ $recover_try -le 2 ]] && [[ $status -eq 2 || $status -eq 5 ]]; do
    if [[ $status -eq 2 ]]; then
      echo "E_TAB_NOT_FOUND.retry attempt=${recover_try}" >&2
    fi
    if [[ -n "${CHATGPT_URL:-}" ]] && is_chat_conversation_url "$CHATGPT_URL"; then
      cdp_activate_or_open_url "$CHATGPT_URL" || maybe_cdp_recover "status${status}_convo_target" "$CHATGPT_URL" || exit 1
    else
      maybe_cdp_recover "status${status}_home_target" "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
    fi
    sleep 0.2
    set +e
    run_send_checked "retry_status${status}_tab_recover_${recover_try}"
    status=$?
    set -e
    recover_try=$((recover_try+1))
  done
fi

if [[ $status -eq 1 ]] && [[ $tab_recover_attempted -eq 1 ]]; then
  # One controlled recover after tab-not-found branch to avoid noisy fail loops.
  echo "E_CDP_UNREACHABLE.recover_once reason=post_tab_recover" >&2
  maybe_cdp_recover "status1_post_tab_recover" "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
  sleep 0.5
  set +e
  run_send_checked "retry_post_tab_recover"
  status=$?
  set -e
fi

if [[ $status -eq 4 ]]; then
  budget_handled_st=0
  if ! timeout_budget_record_event "status4_timeout"; then
    set +e
    timeout_budget_handle_exceeded
    budget_handled_st=$?
    set -e
    if [[ $budget_handled_st -ne 0 ]]; then
      exit "$budget_handled_st"
    fi
  fi
  # Controlled one-shot retry for transient Runtime.evaluate/CDP method timeouts.
  echo "RETRY_CLASS class=soft_reset reason=status4_timeout run_id=${RUN_ID}" >&2
  set +e
  soft_reset_via_cdp "status4_timeout"
  soft_reset_st=$?
  set -e
  if [[ $soft_reset_st -ne 0 ]]; then
    if [[ -n "${CHATGPT_URL:-}" ]] && is_chat_conversation_url "$CHATGPT_URL"; then
      cdp_activate_or_open_url "$CHATGPT_URL" || maybe_cdp_recover "status4_timeout_convo_target" "$CHATGPT_URL" || exit 1
    else
      maybe_cdp_recover "status4_timeout_home_target" "${CHATGPT_URL:-https://chatgpt.com/}" || exit 1
    fi
  fi
  echo "E_CDP_TIMEOUT_RETRY attempt=1" >&2
  sleep 0.2
  set +e
  run_send_checked "retry_status4_timeout"
  status=$?
  set -e
fi

if [[ $status -ne 0 ]]; then
  protocol_append_event "SEND" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "cdp_status=${status}"
  protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=send cdp_status=${status}"
  RUN_OUTCOME="cdp_status_${status}"
  echo "chatgpt_send failed (cdp status=$status)." >&2
  # Keep browser visible for manual inspection.
  if [[ -n "${CHATGPT_URL:-}" ]]; then
    cdp_activate_or_open_url "$CHATGPT_URL" || true
  fi
  exit $status
fi

send_confirm_mode="skip_verify"
if [[ "${PROTO_ENFORCE_POSTSEND_VERIFY:-1}" == "1" ]]; then
  set +e
  postsend_verify_latest_user
  postsend_status=$?
  set -e
  if [[ $postsend_status -eq 0 ]]; then
    send_confirm_mode="fetch_last"
    echo "SEND_CONFIRMED mode=fetch_last_verify attempt=1 run_id=${RUN_ID}" >&2
  elif [[ $postsend_status -eq 2 ]]; then
    protocol_append_event "SEND" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=confirm_route_mismatch status=${postsend_status}"
    protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=postsend_verify route_mismatch"
    RUN_OUTCOME="send_confirm_route_mismatch"
    echo "chatgpt_send failed (postsend route mismatch)." >&2
    exit 2
  else
    echo "E_SEND_NOT_CONFIRMED status=${postsend_status} mode=fetch_last_verify run_id=${RUN_ID}" >&2
    capture_evidence_snapshot "E_SEND_NOT_CONFIRMED" || true
    protocol_append_event "SEND" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=confirm_missing status=${postsend_status}"
    protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=send_confirm status=${postsend_status}"
    RUN_OUTCOME="send_not_confirmed"
    exit 81
  fi
else
  echo "SEND_CONFIRMED mode=skip_verify attempt=1 run_id=${RUN_ID}" >&2
fi
protocol_append_event "SEND" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=dispatch_confirmed mode=${send_confirm_mode}"

if [[ "${REPLY_POLLING}" == "1" ]]; then
  set +e
  reply_wait_collect_via_probe
  reply_status=$?
  set -e
  if [[ $reply_status -ne 0 ]]; then
    if [[ $reply_status -eq 2 ]]; then
      protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=reply_wait route_mismatch"
      RUN_OUTCOME="reply_wait_route_mismatch"
      echo "chatgpt_send failed (reply wait route mismatch)." >&2
      exit 2
    fi
    if [[ $reply_status -eq 76 ]]; then
      protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=reply_wait timeout"
      RUN_OUTCOME="reply_wait_timeout"
      exit 76
    fi
    protocol_append_event "FAIL" "fail" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=reply_wait status=${reply_status}"
    RUN_OUTCOME="reply_wait_status_${reply_status}"
    echo "chatgpt_send failed (reply wait status=$reply_status)." >&2
    exit "$reply_status"
  fi
fi
protocol_append_event "REPLY_READY" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "stage=reply_wait_ready"

# Ensure the chat stays visible for the human: after automation, bring the
# conversation tab to the front in the shared Chrome.
if cdp_is_up; then
  if [[ -n "${CHATGPT_URL:-}" ]] && is_chat_conversation_url "$CHATGPT_URL"; then
    cdp_activate_or_open_url "$CHATGPT_URL" || true
    if [[ "${STRICT_SINGLE_CHAT}" == "1" ]]; then
      ensure_single_chat_target "$CHATGPT_URL" || exit 78
    else
      cdp_cleanup_chat_tabs "$CHATGPT_URL" || true
    fi
  fi
fi

# If we didn't have a conversation URL before (or we started from https://chatgpt.com/),
# try to pin it now (after the first message creates the conversation and the
# /c/<id> URL exists).
if [[ $has_convo_url -eq 0 ]] && cdp_is_up; then
  post_chat_urls="$(capture_chat_urls_from_cdp | sort -u || true)"
  new_chat_url=""
  new_title=""
  if [[ -n "${post_chat_urls//[[:space:]]/}" ]]; then
    # Prefer a newly-created URL (post - pre).
    if [[ -n "${pre_chat_urls//[[:space:]]/}" ]]; then
      new_chat_url="$(comm -13 <(printf '%s\n' "$pre_chat_urls") <(printf '%s\n' "$post_chat_urls") | head -n 1 || true)"
    fi
    # Fallback: if there is exactly one chat URL open, pick it.
    if [[ -z "${new_chat_url:-}" ]]; then
      if [[ "$(printf '%s\n' "$post_chat_urls" | sed '/^$/d' | wc -l)" -eq 1 ]]; then
        new_chat_url="$(printf '%s\n' "$post_chat_urls" | sed '/^$/d' | head -n 1)"
      fi
    fi
  fi
  if [[ -z "${new_chat_url:-}" ]]; then
    # Fallback for shared/multi-tab mode: pick the last visible chat tab.
    # This keeps child runs from ending with empty EVIDENCE when many chats are open.
    fallback_tab="$(capture_chat_tab_from_cdp_last || true)"
    fallback_url="${fallback_tab%%$'\t'*}"
    if [[ -n "${fallback_url:-}" ]] && [[ "$fallback_url" != "$fallback_tab" ]] && is_chat_conversation_url "$fallback_url"; then
      new_chat_url="$fallback_url"
      fallback_title="${fallback_tab#*$'\t'}"
      if [[ "$fallback_title" != "$fallback_tab" ]]; then
        new_title="$fallback_title"
      fi
    fi
  fi

  if [[ -n "${new_chat_url:-}" ]] && is_chat_conversation_url "$new_chat_url"; then
    if [[ -z "${new_title:-}" ]]; then
      new_title="$(capture_chat_title_for_url_from_cdp "$new_chat_url" | head -n 1 || true)"
    fi
    mkdir -p "$(dirname "$CHATGPT_URL_FILE")" >/dev/null 2>&1 || true
    printf '%s\n' "$new_chat_url" >"$CHATGPT_URL_FILE"
    write_work_chat_url "$new_chat_url"
    # Save as last + active session name if needed.
    chats_db_upsert "last" "$new_chat_url" "${new_title:-}" >/dev/null 2>&1 || true
    if [[ "${EXPLICIT_HOME_PROBE}" == "1" ]]; then
      echo "[P2] active_update=skipped reason=explicit_home_probe old_active=${OLD_ACTIVE_URL:-"(none)"} new_candidate=${new_chat_url}" >&2
    else
      existing="$(chats_db_find_name_by_url "$new_chat_url" | head -n 1 || true)"
      if [[ -z "${existing:-}" ]] || [[ "$existing" == "last" ]]; then
        if [[ -n "${INIT_SESSION_NAME:-}" ]]; then
          name="$INIT_SESSION_NAME"
          title="${INIT_SESSION_TITLE:-$new_title}"
        else
          name="$(autoname)"
          title="${new_title:-}"
        fi
        name="$(chats_db_unique_name "$name")"
        chats_db_upsert "$name" "$new_chat_url" "${title:-}" >/dev/null 2>&1 || true
        chats_db_set_active "$name" >/dev/null 2>&1 || true
      else
        chats_db_set_active "$existing" >/dev/null 2>&1 || true
      fi
    fi

    # Make sure the newly created chat is visible in the browser.
    cdp_activate_or_open_url "$new_chat_url" || true
    cdp_cleanup_chat_tabs "$new_chat_url" || true
  fi
fi

if [[ "${EXPLICIT_HOME_PROBE}" == "1" ]]; then
  current_active_name="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ "${current_active_name:-}" != "${OLD_ACTIVE_NAME:-}" ]]; then
    chats_db_set_active "${OLD_ACTIVE_NAME:-}" >/dev/null 2>&1 || true
    echo "[P2] active_restore=applied reason=explicit_home_probe old_active=${OLD_ACTIVE_NAME:-"(none)"} old_url=${OLD_ACTIVE_URL:-"(none)"} current_after_restore=${OLD_ACTIVE_NAME:-"(none)"}" >&2
  fi
fi

record_reply_state_from_output "${ACK_CHAT_ID:-}" "${PROMPT_HASH:-}" "$out"
RUN_OUTCOME="ok"
cat "$out"
}
