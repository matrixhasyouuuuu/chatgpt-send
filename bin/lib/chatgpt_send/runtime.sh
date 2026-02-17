# shellcheck shell=bash
# Runtime send/reply helpers for chatgpt_send.
precheck_via_cdp() {
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "$timeout_s" \
    --prompt "$PROMPT" \
    --precheck-only >"$out"
}

fetch_last_via_cdp() {
  local fetch_n fetch_out st fields fetch_url target_id actual_id checkpoint_id_write
  fetch_n="$FETCH_LAST_N"
  fetch_out="$(mktemp)"
  echo "FETCH_LAST start n=${fetch_n} run_id=${RUN_ID}" >&2
  set +e
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "$timeout_s" \
    --prompt "$PROMPT" \
    --fetch-last \
    --fetch-last-n "$fetch_n" >"$fetch_out"
  st=$?
  set -e
  if [[ $st -ne 0 ]]; then
    protocol_append_event "FETCH_LAST" "fail" "$PROMPT_HASH" "$(read_last_specialist_checkpoint_id | head -n 1 || true)" "status=${st}"
    rm -f "$fetch_out"
    echo "FETCH_LAST fail status=${st} run_id=${RUN_ID}" >&2
    return "$st"
  fi

  fields="$(fetch_last_extract_fields "$fetch_out" || true)"
  if [[ -z "${fields:-}" ]]; then
    protocol_append_event "FETCH_LAST" "fail" "$PROMPT_HASH" "$(read_last_specialist_checkpoint_id | head -n 1 || true)" "status=parse_empty"
    rm -f "$fetch_out"
    echo "FETCH_LAST fail status=parse_empty run_id=${RUN_ID}" >&2
    return 79
  fi
  IFS=$'\t' read -r fetch_url FETCH_LAST_USER_TAIL_HASH FETCH_LAST_ASSISTANT_TAIL_HASH FETCH_LAST_CHECKPOINT_ID FETCH_LAST_LAST_USER_HASH FETCH_LAST_ASSISTANT_AFTER_LAST_USER <<<"$fields"

  target_id="$(chat_id_from_url "${CHATGPT_URL:-}" 2>/dev/null || true)"
  actual_id="$(chat_id_from_url "${fetch_url:-}" 2>/dev/null || true)"
  echo "CHAT_TARGET_URL=${CHATGPT_URL:-none}" >&2
  echo "CHAT_ACTUAL_URL=${fetch_url:-none}" >&2
  if [[ -n "${target_id:-}" ]] && [[ -n "${actual_id:-}" ]] && [[ "${target_id}" == "${actual_id}" ]]; then
    echo "CHAT_ROUTE=OK run_id=${RUN_ID}" >&2
  else
    echo "CHAT_ROUTE=E_ROUTE_MISMATCH expected=${target_id:-none} got=${actual_id:-none} run_id=${RUN_ID}" >&2
    protocol_append_event "FETCH_LAST" "fail" "$PROMPT_HASH" "$(read_last_specialist_checkpoint_id | head -n 1 || true)" "route_mismatch expected=${target_id:-none} got=${actual_id:-none}"
    rm -f "$fetch_out"
    return 72
  fi

  checkpoint_id_write="$(write_last_specialist_checkpoint_from_fetch "$fetch_out" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${checkpoint_id_write:-}" ]]; then
    FETCH_LAST_CHECKPOINT_ID="$checkpoint_id_write"
  fi
  if [[ -z "${FETCH_LAST_CHECKPOINT_ID:-}" ]]; then
    FETCH_LAST_CHECKPOINT_ID="$(read_last_specialist_checkpoint_id | head -n 1 || true)"
  fi
  protocol_append_event "FETCH_LAST" "ok" "$PROMPT_HASH" "${FETCH_LAST_CHECKPOINT_ID:-}" "user_tail_hash=${FETCH_LAST_USER_TAIL_HASH:-none} asst_tail_hash=${FETCH_LAST_ASSISTANT_TAIL_HASH:-none}"
  echo "FETCH_LAST done user_tail_hash=${FETCH_LAST_USER_TAIL_HASH:-none} asst_tail_hash=${FETCH_LAST_ASSISTANT_TAIL_HASH:-none} run_id=${RUN_ID}" >&2

  FETCH_LAST_JSON="$fetch_out"
  return 0
}

late_reply_recover_via_fetch_last() {
  # Usage: late_reply_recover_via_fetch_last <timeout_class> <elapsed_ms> <trigger>
  # Returns 0 when we captured a stable late reply into $out (without resend).
  local timeout_class="${1:-unknown}"
  local elapsed_ms="${2:-0}"
  local trigger="${3:-unknown}"
  local grace_sec poll_ms stable_need poll_s start_ms now_ms max_ms
  local tmp st fields f_url f_user_tail f_asst_tail f_ckpt f_user_hash f_after_anchor
  local candidate stable_ticks prev_hash checkpoint_id_write

  grace_sec="${LATE_REPLY_GRACE_SEC:-30}"
  poll_ms="${LATE_REPLY_POLL_MS:-1500}"
  stable_need="${LATE_REPLY_STABLE_TICKS:-2}"

  [[ "$grace_sec" =~ ^[0-9]+$ ]] || grace_sec=30
  [[ "$poll_ms" =~ ^[0-9]+$ ]] || poll_ms=1500
  [[ "$stable_need" =~ ^[0-9]+$ ]] || stable_need=2
  (( grace_sec < 0 )) && grace_sec=0
  (( poll_ms < 100 )) && poll_ms=100
  (( stable_need < 1 )) && stable_need=1

  # This grace recovery is specifically for stop-visible instability cases.
  if [[ "$timeout_class" != "stop_visible" ]] || (( grace_sec == 0 )); then
    return 1
  fi

  poll_s="$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')"
  start_ms="$(now_ms)"
  max_ms=$((grace_sec * 1000))
  stable_ticks=0
  prev_hash=""

  echo "REPLY_LATE_RECOVERY start class=${timeout_class} grace_sec=${grace_sec} poll_ms=${poll_ms} stable_need=${stable_need} run_id=${RUN_ID}" >&2
  while true; do
    now_ms="$(now_ms)"
    if (( now_ms - start_ms >= max_ms )); then
      break
    fi

    tmp="$(mktemp)"
    set +e
    python3 "$ROOT/bin/cdp_chatgpt.py" \
      --cdp-port "$CDP_PORT" \
      --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
      --timeout "$timeout_s" \
      --prompt "$PROMPT" \
      --fetch-last \
      --fetch-last-n "${FETCH_LAST_N}" >"$tmp"
    st=$?
    set -e

    if [[ $st -ne 0 ]]; then
      echo "REPLY_LATE_RECOVERY tick status=${st} run_id=${RUN_ID}" >&2
      rm -f "$tmp"
      sleep "$poll_s"
      continue
    fi

    fields="$(fetch_last_extract_fields "$tmp" || true)"
    if [[ -z "${fields:-}" ]]; then
      echo "REPLY_LATE_RECOVERY tick status=parse_empty run_id=${RUN_ID}" >&2
      rm -f "$tmp"
      sleep "$poll_s"
      continue
    fi
    IFS=$'\t' read -r f_url f_user_tail f_asst_tail f_ckpt f_user_hash f_after_anchor <<<"$fields"

    candidate=0
    if [[ "${f_after_anchor}" == "1" ]] && [[ -n "${f_asst_tail:-}" ]] && [[ "${f_user_hash:-}" == "${PROMPT_HASH:-}" ]]; then
      candidate=1
      if [[ "${f_asst_tail}" == "${prev_hash}" ]]; then
        stable_ticks=$((stable_ticks + 1))
      else
        stable_ticks=1
        prev_hash="${f_asst_tail}"
      fi
    else
      stable_ticks=0
      prev_hash=""
    fi

    echo "REPLY_LATE_RECOVERY tick candidate=${candidate} stable_ticks=${stable_ticks} hash=${f_asst_tail:-none} run_id=${RUN_ID}" >&2
    if (( candidate == 1 )) && (( stable_ticks >= stable_need )); then
      if fetch_last_reuse_text_for_prompt "$tmp" "${PROMPT_HASH:-}" >"$out"; then
        checkpoint_id_write="$(write_last_specialist_checkpoint_from_fetch "$tmp" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${checkpoint_id_write:-}" ]]; then
          FETCH_LAST_CHECKPOINT_ID="$checkpoint_id_write"
        elif [[ -n "${f_ckpt:-}" ]]; then
          FETCH_LAST_CHECKPOINT_ID="$f_ckpt"
        fi
        echo "REPLY_CAPTURE reuse_existing=1 source=late_recovery class=${timeout_class} run_id=${RUN_ID}" >&2
        echo "W_REPLY_LATE_ARRIVAL class=${timeout_class} elapsed_ms=${elapsed_ms} trigger=${trigger} run_id=${RUN_ID}" >&2
        rm -f "$tmp"
        return 0
      fi
    fi

    rm -f "$tmp"
    sleep "$poll_s"
  done

  echo "REPLY_LATE_RECOVERY done outcome=not_ready class=${timeout_class} run_id=${RUN_ID}" >&2
  return 1
}

contract_probe_via_cdp() {
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "$timeout_s" \
    --prompt "$PROMPT" \
    --probe-contract >/dev/null
}

precheck_auto_wait_loop() {
  local max_sec poll_ms poll_s start_ms now elapsed_ms max_ms precheck_status
  max_sec="$AUTO_WAIT_MAX_SEC"
  poll_ms="$AUTO_WAIT_POLL_MS"
  [[ "$max_sec" =~ ^[0-9]+$ ]] || max_sec=60
  [[ "$poll_ms" =~ ^[0-9]+$ ]] || poll_ms=500
  (( max_sec < 1 )) && max_sec=1
  (( poll_ms < 50 )) && poll_ms=50
  poll_s="$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')"
  start_ms="$(now_ms)"
  max_ms=$((max_sec * 1000))

  echo "AUTO_WAIT start max_sec=${max_sec} poll_ms=${poll_ms} run_id=${RUN_ID}" >&2
  while true; do
    sleep "$poll_s"
    now="$(now_ms)"
    elapsed_ms=$((now - start_ms))
    echo "AUTO_WAIT tick elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
    if (( elapsed_ms >= max_ms )); then
      echo "AUTO_WAIT done outcome=timeout elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
      echo "E_AUTO_WAIT_TIMEOUT elapsed_ms=${elapsed_ms} max_sec=${max_sec} run_id=${RUN_ID}" >&2
      return 73
    fi

    precheck_via_cdp
    precheck_status=$?

    if [[ $precheck_status -eq 11 ]]; then
      continue
    fi
    if [[ $precheck_status -eq 0 ]]; then
      echo "AUTO_WAIT done outcome=reuse elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
      return 0
    fi
    if [[ $precheck_status -eq 10 ]]; then
      echo "AUTO_WAIT done outcome=send elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
      return 10
    fi
    echo "AUTO_WAIT done outcome=precheck_status${precheck_status} elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
    return "$precheck_status"
  done
}

run_send_checked() {
  local stage="${1:-send}"
  if [[ "${PRECHECK_DONE}" != "1" ]]; then
    echo "E_SEND_WITHOUT_PRECHECK stage=${stage} run_id=${RUN_ID}" >&2
    return 71
  fi
  log_action "send" "stage=${stage}"
  if [[ "${REPLY_POLLING}" == "1" ]]; then
    send_no_wait_via_cdp
  else
    send_via_cdp
  fi
}

# Use CDP to type/click in the existing, visible ChatGPT tab and then scrape
# the final assistant response.
send_via_cdp() {
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "$timeout_s" \
    --prompt "$PROMPT" >"$out"
}

send_no_wait_via_cdp() {
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "$timeout_s" \
    --prompt "$PROMPT" \
    --send-no-wait >"$out"
}

reply_ready_probe_via_cdp() {
  local probe_log="${1:-/dev/null}"
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "20" \
    --prompt "$PROMPT" \
    --reply-ready-probe >"$probe_log" 2>&1
}

current_run_dir() {
  if [[ -n "${LOG_DIR//[[:space:]]/}" ]]; then
    printf '%s\n' "$LOG_DIR"
  else
    printf '%s\n' "$ROOT/state/runs/$RUN_ID"
  fi
}

RUN_SUMMARY_ENABLED=0
RUN_SUMMARY_WRITTEN=0
RUN_OUTCOME="unknown"
RUN_STARTED_MS=0

write_run_manifest() {
  local run_dir manifest_path ts_start
  run_dir="$(current_run_dir)"
  mkdir -p "$run_dir" >/dev/null 2>&1 || return 0
  manifest_path="$run_dir/manifest.json"
  ts_start="$(date +%s)"
  python3 - "$manifest_path" "$RUN_ID" "$ts_start" "$ROOT" "$CDP_PORT" \
    "${CHATGPT_URL:-}" "${WORK_CHAT_URL:-}" "${PROMPT_HASH:-}" \
    "${STRICT_SINGLE_CHAT:-0}" "${STRICT_SINGLE_CHAT_ACTION:-block}" <<'PY'
import json,sys
out, run_id, ts_start, root, cdp_port, chat_url, work_chat_url, prompt_hash, strict_single_chat, strict_action = sys.argv[1:]
obj = {
    "run_id": run_id,
    "ts_start": int(ts_start or 0),
    "root": root,
    "cdp_port": int(cdp_port or 0),
    "chat_url": chat_url,
    "work_chat_url": work_chat_url,
    "prompt_hash": prompt_hash,
    "strict_single_chat": int(strict_single_chat or 0),
    "strict_single_chat_action": strict_action,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, sort_keys=True)
PY
}

write_run_summary() {
  local exit_status="$1"
  local run_dir summary_path ts_end ended_ms duration_ms
  run_dir="$(current_run_dir)"
  mkdir -p "$run_dir" >/dev/null 2>&1 || return 0
  summary_path="$run_dir/summary.json"
  ts_end="$(date +%s)"
  ended_ms="$(now_ms)"
  duration_ms=0
  if [[ "${RUN_STARTED_MS:-0}" =~ ^[0-9]+$ ]] && [[ "${ended_ms:-0}" =~ ^[0-9]+$ ]]; then
    duration_ms=$((ended_ms - RUN_STARTED_MS))
    (( duration_ms < 0 )) && duration_ms=0
  fi
  python3 - "$summary_path" "$RUN_ID" "$ts_end" "$duration_ms" "$exit_status" "$RUN_OUTCOME" \
    "${CHATGPT_URL:-}" "${WORK_CHAT_URL:-}" "$(current_run_dir)" <<'PY'
import json,sys
out, run_id, ts_end, duration_ms, exit_status, outcome, chat_url, work_chat_url, run_dir = sys.argv[1:]
obj = {
    "run_id": run_id,
    "ts_end": int(ts_end or 0),
    "duration_ms": int(duration_ms or 0),
    "exit_status": int(exit_status or 0),
    "outcome": outcome or "unknown",
    "chat_url": chat_url,
    "work_chat_url": work_chat_url,
    "run_dir": run_dir,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, sort_keys=True)
PY
}

run_summary_finalize_on_exit() {
  local st="$?"
  if [[ "${RUN_SUMMARY_ENABLED}" != "1" ]]; then
    return
  fi
  if [[ "${RUN_SUMMARY_WRITTEN}" == "1" ]]; then
    return
  fi
  if [[ "${RUN_OUTCOME}" == "unknown" ]]; then
    if [[ "$st" -eq 0 ]]; then
      RUN_OUTCOME="ok"
    else
      RUN_OUTCOME="exit_${st}"
    fi
  fi
  set +e
  write_run_summary "$st"
  RUN_SUMMARY_WRITTEN=1
  set -e
}

capture_evidence_snapshot() {
  local reason="${1:-unknown}"
  local probe_log="${2:-}"
  local run_dir ev_dir ts tabs_json version_json chrome_pid
  local contract_tmp contract_status contract_line contract_fail_line
  local probe_reason progress_line progress_after_anchor progress_tail_len progress_tail_hash progress_stop_visible
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac

  [[ "${CAPTURE_EVIDENCE}" == "1" ]] || return 0

  run_dir="$(current_run_dir)"
  ev_dir="$run_dir/evidence"
  mkdir -p "$ev_dir" >/dev/null 2>&1 || return 0
  ts="$(date +%s)"

  tabs_json="$ev_dir/tabs.json"
  version_json="$ev_dir/version.json"
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" >"$tabs_json" 2>/dev/null || printf '%s\n' '[]' >"$tabs_json"
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >"$version_json" 2>/dev/null || printf '%s\n' '{}' >"$version_json"

  contract_tmp="$(mktemp)"
  set +e
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "20" \
    --prompt "$PROMPT" \
    --probe-contract >/dev/null 2>"$contract_tmp"
  contract_status=$?
  if [[ $had_errexit -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  contract_line="$(sed -n 's/^UI_CONTRACT: //p' "$contract_tmp" | tail -n 1)"
  contract_fail_line="$(sed -n 's/^E_UI_CONTRACT_FAIL: //p' "$contract_tmp" | tail -n 1)"
  python3 - "$ev_dir/contract.json" "$contract_status" "$contract_line" "$contract_fail_line" "$ts" "$RUN_ID" "$reason" <<'PY'
import json,sys
out, st, line, fail, ts, run_id, reason = sys.argv[1:]
obj = {
    "ts": int(ts),
    "run_id": run_id,
    "reason": reason,
    "status": int(st),
    "ui_contract": line,
    "ui_contract_fail": fail,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, sort_keys=True)
PY
  rm -f "$contract_tmp"

  probe_reason="none"
  progress_line=""
  progress_after_anchor="0"
  progress_tail_len="0"
  progress_tail_hash="none"
  progress_stop_visible="0"
  if [[ -n "${probe_log:-}" ]] && [[ -f "$probe_log" ]]; then
    probe_reason="$(sed -n 's/^REPLY_READY: 0 reason=//p' "$probe_log" | tail -n 1)"
    [[ -n "${probe_reason:-}" ]] || probe_reason="none"
    progress_line="$(sed -n 's/^REPLY_PROGRESS //p' "$probe_log" | tail -n 1)"
    progress_after_anchor="$(printf '%s\n' "$progress_line" | sed -n 's/.*assistant_after_anchor=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    progress_tail_len="$(printf '%s\n' "$progress_line" | sed -n 's/.*assistant_tail_len=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    progress_tail_hash="$(printf '%s\n' "$progress_line" | sed -n 's/.*assistant_tail_hash=\([^[:space:]]*\).*/\1/p' | tail -n 1)"
    progress_stop_visible="$(printf '%s\n' "$progress_line" | sed -n 's/.*stop_visible=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    [[ -n "${progress_after_anchor:-}" ]] || progress_after_anchor="0"
    [[ -n "${progress_tail_len:-}" ]] || progress_tail_len="0"
    [[ -n "${progress_tail_hash:-}" ]] || progress_tail_hash="none"
    [[ -n "${progress_stop_visible:-}" ]] || progress_stop_visible="0"
  fi
  python3 - "$ev_dir/probe_last.json" "$ts" "$RUN_ID" "$reason" "$probe_reason" "$progress_after_anchor" "$progress_tail_len" "$progress_tail_hash" "$progress_stop_visible" <<'PY'
import json,sys
out, ts, run_id, reason, probe_reason, after_anchor, tail_len, tail_hash, stop_visible = sys.argv[1:]
obj = {
    "ts": int(ts),
    "run_id": run_id,
    "reason": reason,
    "probe_reason": probe_reason,
    "assistant_after_anchor": int(after_anchor or 0),
    "assistant_tail_len": int(tail_len or 0),
    "assistant_tail_hash": tail_hash,
    "stop_visible": int(stop_visible or 0),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, sort_keys=True)
PY

  chrome_pid=""
  if [[ -f "$ROOT/state/chrome_${CDP_PORT}.pid" ]]; then
    chrome_pid="$(cat "$ROOT/state/chrome_${CDP_PORT}.pid" 2>/dev/null | tr -d '\n' || true)"
  fi
  python3 - "$ev_dir/process.json" "$ts" "$RUN_ID" "${CHATGPT_URL:-}" "${WORK_CHAT_URL:-}" "$CDP_PORT" "${chrome_pid:-}" "${LOCK_FILE:-}" <<'PY'
import json,sys
out, ts, run_id, chat_url, work_chat_url, cdp_port, chrome_pid, lock_file = sys.argv[1:]
obj = {
    "ts": int(ts),
    "run_id": run_id,
    "chatgpt_url": chat_url,
    "work_chat_url": work_chat_url,
    "cdp_port": int(cdp_port or 0),
    "chrome_pid": chrome_pid,
    "lock_file": lock_file,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, sort_keys=True)
PY

  python3 - "$ev_dir/doctor.jsonl" "$ts" "$RUN_ID" "${CHATGPT_URL:-}" "${WORK_CHAT_URL:-}" "$CDP_PORT" "$ROOT" <<'PY'
import json,sys
out, ts, run_id, chat_url, work_chat_url, cdp_port, root = sys.argv[1:]
obj = {
    "ts": int(ts),
    "run_id": run_id,
    "root": root,
    "chatgpt_url": chat_url,
    "work_chat_url": work_chat_url,
    "cdp_port": int(cdp_port or 0),
}
with open(out, "w", encoding="utf-8") as f:
    f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True) + "\n")
PY

  sanitize_file_inplace "$tabs_json"
  sanitize_file_inplace "$version_json"
  sanitize_file_inplace "$ev_dir/contract.json"
  sanitize_file_inplace "$ev_dir/probe_last.json"
  sanitize_file_inplace "$ev_dir/process.json"
  sanitize_file_inplace "$ev_dir/doctor.jsonl"

  echo "EVIDENCE_CAPTURED reason=${reason} dir=${ev_dir} run_id=${RUN_ID}" >&2
}

soft_reset_via_cdp() {
  local reason="${1:-status4_timeout}"
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  set +e
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${CHATGPT_URL:-https://chatgpt.com/}" \
    --timeout "120" \
    --prompt "$PROMPT" \
    --soft-reset-only \
    --soft-reset-reason "$reason" >/dev/null
  st=$?
  if [[ $had_errexit -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ $st -ne 0 ]]; then
    capture_evidence_snapshot "E_SOFT_RESET_FAILED"
  fi
  return $st
}

record_reply_state_from_output() {
  # Usage: record_reply_state_from_output <chat_id> <prompt_hash> <out_file>
  local chat_id="$1"
  local prompt_hash="$2"
  local out_file="$3"
  local text reply_fp anchor_id
  [[ -n "${chat_id:-}" ]] || return 0
  [[ -f "$out_file" ]] || return 0
  text="$(cat "$out_file" 2>/dev/null || true)"
  if [[ -z "${text//[[:space:]]/}" ]]; then
    return 0
  fi
  reply_fp="$(printf '%s' "$text" | stable_hash)"
  [[ -n "${reply_fp:-}" ]] || return 0
  anchor_id="${prompt_hash:-}"
  ack_db_mark_reply "$chat_id" "$reply_fp" "$anchor_id" "$prompt_hash"
  echo "REPLY_TRACK_WRITE chat_id=${chat_id} reply_fingerprint=${reply_fp} anchor_id=${anchor_id:-none} prompt_hash=${prompt_hash:-none} run_id=${RUN_ID}" >&2
}

reply_wait_collect_via_probe() {
  local max_sec poll_ms poll_s start_ms now elapsed_ms max_ms
  local no_progress_max_ms no_progress_ms last_elapsed_ms last_tail_hash progress_ticks
  local probe_status fetch_status probe_status_last fetch_status_last
  local probe_reason probe_reason_last timeout_class probe_log timeout_trigger
  local progress_line progress_after_anchor progress_tail_hash progress_stop_visible
  local stop_visible_ticks ticks cdp_errors_seen post_reset soft_reset_st delta_ms
  max_sec="$REPLY_MAX_SEC"
  poll_ms="$REPLY_POLL_MS"
  no_progress_max_ms="$REPLY_NO_PROGRESS_MAX_MS"
  [[ "$max_sec" =~ ^[0-9]+$ ]] || max_sec=90
  [[ "$poll_ms" =~ ^[0-9]+$ ]] || poll_ms=700
  [[ "$no_progress_max_ms" =~ ^[0-9]+$ ]] || no_progress_max_ms=45000
  (( max_sec < 1 )) && max_sec=1
  (( poll_ms < 100 )) && poll_ms=100
  (( no_progress_max_ms < 0 )) && no_progress_max_ms=0
  poll_s="$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')"
  start_ms="$(now_ms)"
  max_ms=$((max_sec * 1000))
  probe_status_last=-1
  fetch_status_last=-1
  probe_reason_last="none"
  stop_visible_ticks=0
  ticks=0
  cdp_errors_seen=0
  post_reset=0
  no_progress_ms=0
  last_elapsed_ms=0
  last_tail_hash=""
  progress_ticks=0
  probe_log="$(mktemp)"

  reply_wait_timeout_exit() {
    local elapsed_ms_local="$1"
    local timeout_trigger_local="$2"
    local timeout_class_local
    timeout_class_local="no_activity"
    if [[ $stop_visible_ticks -gt 0 ]]; then
      timeout_class_local="stop_visible"
    fi

    if [[ "$timeout_class_local" == "stop_visible" ]] && [[ $post_reset -eq 0 ]]; then
      echo "REPLY_WAIT recovery=soft_reset reason=stop_visible_timeout elapsed_ms=${elapsed_ms_local} trigger=${timeout_trigger_local} run_id=${RUN_ID}" >&2
      set +e
      soft_reset_via_cdp "stop_visible_timeout"
      soft_reset_st=$?
      set -e
      if [[ $soft_reset_st -eq 0 ]]; then
        post_reset=1
        set +e
        precheck_via_cdp
        fetch_status=$?
        set -e
        fetch_status_last=$fetch_status
        if [[ $fetch_status -eq 0 ]]; then
          echo "REPLY_WAIT done outcome=ready_after_reset elapsed_ms=${elapsed_ms_local} trigger=${timeout_trigger_local} run_id=${RUN_ID}" >&2
          rm -f "$probe_log"
          return 0
        fi
        if [[ $fetch_status -eq 2 ]]; then
          echo "REPLY_WAIT done outcome=route_mismatch_after_reset elapsed_ms=${elapsed_ms_local} trigger=${timeout_trigger_local} run_id=${RUN_ID}" >&2
          rm -f "$probe_log"
          return 2
        fi
      else
        cdp_errors_seen=$((cdp_errors_seen + 1))
      fi
    fi

    if late_reply_recover_via_fetch_last "$timeout_class_local" "$elapsed_ms_local" "$timeout_trigger_local"; then
      echo "REPLY_WAIT done outcome=ready_late_recovery elapsed_ms=${elapsed_ms_local} trigger=${timeout_trigger_local} run_id=${RUN_ID}" >&2
      rm -f "$probe_log"
      return 0
    fi

    echo "REPLY_WAIT done outcome=timeout elapsed_ms=${elapsed_ms_local} trigger=${timeout_trigger_local} run_id=${RUN_ID}" >&2
    echo "E_REPLY_WAIT_TIMEOUT class=${timeout_class_local} elapsed_ms=${elapsed_ms_local} max_sec=${max_sec} timeout_trigger=${timeout_trigger_local} ticks=${ticks} stop_visible_ticks=${stop_visible_ticks} no_progress_ms=${no_progress_ms} no_progress_max_ms=${no_progress_max_ms} progress_ticks=${progress_ticks} last_reason=${probe_reason_last} probe_status_last=${probe_status_last} fetch_status_last=${fetch_status_last} cdp_errors_seen=${cdp_errors_seen} post_reset=${post_reset} run_id=${RUN_ID}" >&2
    if [[ "$timeout_class_local" == "stop_visible" ]]; then
      echo "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE elapsed_ms=${elapsed_ms_local} max_sec=${max_sec} trigger=${timeout_trigger_local} post_reset=${post_reset} run_id=${RUN_ID}" >&2
    else
      echo "E_REPLY_WAIT_TIMEOUT_NO_ACTIVITY elapsed_ms=${elapsed_ms_local} max_sec=${max_sec} trigger=${timeout_trigger_local} post_reset=${post_reset} run_id=${RUN_ID}" >&2
    fi
    capture_evidence_snapshot "E_REPLY_WAIT_TIMEOUT_${timeout_class_local}" "$probe_log"
    rm -f "$probe_log"
    return 76
  }

  echo "REPLY_WAIT start max_sec=${max_sec} poll_ms=${poll_ms} no_progress_max_ms=${no_progress_max_ms} run_id=${RUN_ID}" >&2
  while true; do
    now="$(now_ms)"
    elapsed_ms=$((now - start_ms))
    if (( elapsed_ms >= max_ms )); then
      reply_wait_timeout_exit "$elapsed_ms" "wall_clock"
      return $?
    fi

    ticks=$((ticks + 1))
    : >"$probe_log"
    set +e
    reply_ready_probe_via_cdp "$probe_log"
    probe_status=$?
    set -e
    probe_status_last=$probe_status
    probe_reason="$(sed -n 's/^REPLY_READY: 0 reason=//p' "$probe_log" | tail -n 1)"
    if [[ -z "${probe_reason:-}" ]]; then
      if grep -q '^REPLY_READY: 1' "$probe_log"; then
        probe_reason="ready"
      else
        probe_reason="unknown"
      fi
    fi
    probe_reason_last="$probe_reason"

    progress_line="$(sed -n 's/^REPLY_PROGRESS //p' "$probe_log" | tail -n 1)"
    progress_after_anchor="$(printf '%s\n' "$progress_line" | sed -n 's/.*assistant_after_anchor=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    progress_tail_hash="$(printf '%s\n' "$progress_line" | sed -n 's/.*assistant_tail_hash=\([^[:space:]]*\).*/\1/p' | tail -n 1)"
    progress_stop_visible="$(printf '%s\n' "$progress_line" | sed -n 's/.*stop_visible=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    [[ -n "${progress_after_anchor:-}" ]] || progress_after_anchor=0
    [[ -n "${progress_tail_hash:-}" ]] || progress_tail_hash="none"
    [[ -n "${progress_stop_visible:-}" ]] || progress_stop_visible=0

    if [[ "$progress_stop_visible" == "1" ]] || [[ "$probe_reason" == "stop_visible" ]]; then
      stop_visible_ticks=$((stop_visible_ticks + 1))
    fi

    delta_ms=$((elapsed_ms - last_elapsed_ms))
    (( delta_ms < 0 )) && delta_ms=0
    last_elapsed_ms=$elapsed_ms

    if [[ "$progress_after_anchor" == "1" ]] && [[ "$progress_tail_hash" != "none" ]] && [[ -n "$progress_tail_hash" ]]; then
      if [[ "$progress_tail_hash" != "$last_tail_hash" ]]; then
        progress_ticks=$((progress_ticks + 1))
        last_tail_hash="$progress_tail_hash"
        no_progress_ms=0
      else
        no_progress_ms=$((no_progress_ms + delta_ms))
      fi
    else
      no_progress_ms=$((no_progress_ms + delta_ms))
    fi

    if [[ $probe_status -ne 0 ]] && [[ $probe_status -ne 10 ]] && [[ $probe_status -ne 2 ]]; then
      cdp_errors_seen=$((cdp_errors_seen + 1))
    fi

    if [[ $probe_status -eq 0 ]]; then
      set +e
      precheck_via_cdp
      fetch_status=$?
      set -e
      fetch_status_last=$fetch_status
      if [[ $fetch_status -eq 0 ]]; then
        echo "REPLY_WAIT done outcome=ready elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
        rm -f "$probe_log"
        return 0
      fi
      if [[ $fetch_status -eq 2 ]]; then
        echo "REPLY_WAIT done outcome=route_mismatch elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
        rm -f "$probe_log"
        return 2
      fi
      echo "REPLY_WAIT tick elapsed_ms=${elapsed_ms} probe_status=0 reason=${probe_reason} fetch_status=${fetch_status} no_progress_ms=${no_progress_ms} progress_ticks=${progress_ticks} run_id=${RUN_ID}" >&2
    elif [[ $probe_status -eq 2 ]]; then
      echo "REPLY_WAIT done outcome=route_mismatch elapsed_ms=${elapsed_ms} run_id=${RUN_ID}" >&2
      rm -f "$probe_log"
      return 2
    else
      echo "REPLY_WAIT tick elapsed_ms=${elapsed_ms} probe_status=${probe_status} reason=${probe_reason} no_progress_ms=${no_progress_ms} progress_ticks=${progress_ticks} run_id=${RUN_ID}" >&2
    fi

    if (( no_progress_max_ms > 0 )) && (( no_progress_ms >= no_progress_max_ms )); then
      reply_wait_timeout_exit "$elapsed_ms" "no_progress"
      return $?
    fi

    sleep "$poll_s"
  done
}
