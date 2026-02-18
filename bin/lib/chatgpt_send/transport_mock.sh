# shellcheck shell=bash
# Mock transport helpers for offline Specialist flows.

mock_transport_enabled() {
  [[ "${CHATGPT_SEND_TRANSPORT:-cdp}" == "mock" ]]
}

mock_maybe_fail() {
  local code="${CHATGPT_SEND_MOCK_ERROR_CODE:-}"
  if [[ -z "${code//[[:space:]]/}" ]]; then
    return 0
  fi
  if [[ "$code" =~ ^[0-9]+$ ]] && (( code > 0 )); then
    echo "[E_MOCK_FORCED] code=${code} run_id=${RUN_ID}" >&2
    return "$code"
  fi
  return 0
}

mock_sent_file_path() {
  printf '%s\n' "${CHATGPT_SEND_MOCK_SENT_FILE:-$ROOT/state/mock_sent_count.txt}"
}

mock_read_sent_count() {
  local sent_file count
  sent_file="$(mock_sent_file_path)"
  count="0"
  if [[ -f "$sent_file" ]]; then
    count="$(tr -d '[:space:]' <"$sent_file" 2>/dev/null || true)"
  fi
  [[ "$count" =~ ^[0-9]+$ ]] || count="0"
  printf '%s\n' "$count"
}

mock_increment_sent_count() {
  local sent_file count
  sent_file="$(mock_sent_file_path)"
  mkdir -p "$(dirname "$sent_file")" >/dev/null 2>&1 || true
  count="$(mock_read_sent_count)"
  count=$((count + 1))
  printf '%s\n' "$count" >"$sent_file"
}

mock_pop_first_line() {
  # Usage: mock_pop_first_line <file>
  local src="$1"
  python3 - "$src" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)
lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
picked = ""
rest = []
consumed = False
for ln in lines:
    if not consumed and ln.strip():
        picked = ln.strip()
        consumed = True
        continue
    rest.append(ln)
path.write_text("\n".join(rest) + ("\n" if rest else ""), encoding="utf-8")
if picked:
    print(picked)
PY
}

mock_capture_chat_url() {
  local url=""
  if [[ -n "${CHATGPT_SEND_MOCK_CHAT_URL:-}" ]]; then
    url="${CHATGPT_SEND_MOCK_CHAT_URL:-}"
  elif [[ -n "${CHATGPT_SEND_MOCK_CHAT_URL_FILE:-}" ]]; then
    url="$(mock_pop_first_line "${CHATGPT_SEND_MOCK_CHAT_URL_FILE:-}" | head -n 1 || true)"
  fi
  if [[ -z "${url//[[:space:]]/}" ]]; then
    if [[ -n "${CHATGPT_URL//[[:space:]]/}" ]]; then
      url="${CHATGPT_URL}"
    else
      url="https://chatgpt.com/"
    fi
  fi
  echo "[mock] capture_chat_url url=${url} run_id=${RUN_ID}" >&2
  printf '%s\n' "$url"
}

mock_peek_reply() {
  local reply=""
  if [[ -n "${CHATGPT_SEND_MOCK_REPLY+x}" ]]; then
    reply="${CHATGPT_SEND_MOCK_REPLY}"
  elif [[ -n "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" ]] && [[ -f "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" ]]; then
    reply="$(cat "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" 2>/dev/null || true)"
  elif [[ -n "${CHATGPT_SEND_MOCK_REPLIES_DIR:-}" ]] && [[ -d "${CHATGPT_SEND_MOCK_REPLIES_DIR:-}" ]]; then
    local first_file
    first_file="$(find "${CHATGPT_SEND_MOCK_REPLIES_DIR}" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort | head -n 1 || true)"
    if [[ -n "${first_file:-}" ]]; then
      reply="$(cat "$first_file" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "${reply:-}" ]]; then
    reply="mock reply"
  fi
  printf '%s' "$reply"
}

mock_wait_reply() {
  local reply source first_file bytes
  if [[ -n "${CHATGPT_SEND_MOCK_REPLY+x}" ]]; then
    reply="${CHATGPT_SEND_MOCK_REPLY}"
    source="env_reply"
  elif [[ -n "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" ]] && [[ -f "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" ]]; then
    reply="$(cat "${CHATGPT_SEND_MOCK_REPLY_FILE:-}" 2>/dev/null || true)"
    source="reply_file"
  elif [[ -n "${CHATGPT_SEND_MOCK_REPLIES_DIR:-}" ]] && [[ -d "${CHATGPT_SEND_MOCK_REPLIES_DIR:-}" ]]; then
    first_file="$(find "${CHATGPT_SEND_MOCK_REPLIES_DIR:-}" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort | head -n 1 || true)"
    if [[ -n "${first_file:-}" ]]; then
      reply="$(cat "$first_file" 2>/dev/null || true)"
      rm -f "$first_file" 2>/dev/null || true
      source="replies_dir"
    fi
  fi
  if [[ -z "${reply:-}" ]]; then
    reply="mock reply"
    source="default"
  fi
  bytes="$(printf '%s' "$reply" | wc -c | tr -d ' ')"
  echo "[mock] wait_reply bytes=${bytes} source=${source:-unknown} run_id=${RUN_ID}" >&2
  printf '%s' "$reply"
}

mock_open_browser() {
  local url="${1:-https://chatgpt.com/}"
  if ! mock_maybe_fail; then
    return $?
  fi
  echo "[mock] open_browser skipped url=${url} run_id=${RUN_ID}" >&2
  return 0
}

mock_send_prompt() {
  local prompt_path bytes
  if ! mock_maybe_fail; then
    return $?
  fi
  prompt_path="${CHATGPT_SEND_MOCK_LAST_PROMPT_FILE:-$ROOT/state/mock_last_prompt.txt}"
  mkdir -p "$(dirname "$prompt_path")" >/dev/null 2>&1 || true
  printf '%s' "$PROMPT" >"$prompt_path"
  mock_increment_sent_count
  bytes="$(printf '%s' "$PROMPT" | wc -c | tr -d ' ')"
  echo "[mock] send_prompt bytes=${bytes} path=${prompt_path} run_id=${RUN_ID}" >&2
  return 0
}

mock_precheck() {
  # Usage: mock_precheck <out_file>
  local out_file="$1"
  local sent_count forced_status
  if ! mock_maybe_fail; then
    return $?
  fi
  forced_status="${CHATGPT_SEND_MOCK_PRECHECK_STATUS:-}"
  if [[ "$forced_status" =~ ^[0-9]+$ ]]; then
    if [[ "$forced_status" == "0" ]]; then
      mock_wait_reply >"$out_file"
    else
      printf '%s\n' "E_PRECHECK_MOCK forced_status=${forced_status}" >"$out_file"
    fi
    return "$forced_status"
  fi

  sent_count="$(mock_read_sent_count)"
  if (( sent_count > 0 )); then
    mock_wait_reply >"$out_file"
    return 0
  fi
  printf '%s\n' "E_PRECHECK_NO_NEW_REPLY: need_send" >"$out_file"
  return 10
}

mock_reply_ready_probe() {
  # Usage: mock_reply_ready_probe <probe_log_file>
  local probe_log="$1"
  local sent_count current_url preview preview_hash
  if ! mock_maybe_fail; then
    return $?
  fi
  sent_count="$(mock_read_sent_count)"
  current_url="${CHATGPT_URL:-https://chatgpt.com/}"
  if (( sent_count <= 0 )); then
    {
      echo "REPLY_READY: 0 reason=prompt_not_echoed"
      echo "REPLY_PROGRESS assistant_after_anchor=0 assistant_tail_hash=none stop_visible=0"
    } >"$probe_log"
    return 10
  fi
  if [[ "$current_url" == "https://chatgpt.com/" ]] || [[ "$current_url" == "https://chatgpt.com" ]]; then
    {
      echo "REPLY_READY: 0 reason=route_mismatch"
      echo "REPLY_PROGRESS assistant_after_anchor=0 assistant_tail_hash=none stop_visible=0"
    } >"$probe_log"
    return 2
  fi
  preview="$(mock_peek_reply)"
  preview_hash="$(printf '%s' "$preview" | stable_hash)"
  {
    echo "REPLY_READY: 1"
    echo "REPLY_PROGRESS assistant_after_anchor=1 assistant_tail_hash=${preview_hash:-none} stop_visible=0"
  } >"$probe_log"
  return 0
}

mock_probe_chat() {
  # Usage: mock_probe_chat <chat_url> <out_file>
  local chat_url="$1"
  local out_file="$2"
  local fail_urls tokens token
  if ! mock_maybe_fail; then
    return $?
  fi
  fail_urls="${CHATGPT_SEND_MOCK_PROBE_FAIL_URLS:-}"
  if [[ -n "${fail_urls//[[:space:]]/}" ]]; then
    tokens="$(printf '%s\n' "$fail_urls" | tr ', ' '\n\n' | sed -e '/^[[:space:]]*$/d')"
    while IFS= read -r token; do
      token="$(printf '%s' "$token" | xargs || true)"
      [[ -n "${token:-}" ]] || continue
      if [[ "$token" == "$chat_url" ]]; then
        {
          echo "E_PROBE_CHAT_FAILED url=${chat_url} code=E_MOCK_FORCED_FAIL"
        } >"$out_file"
        return 78
      fi
    done <<<"$tokens"
  fi
  {
    echo "PROBE_CHAT_OK url=${chat_url} prompt_ready=1 transport=mock"
  } >"$out_file"
  return 0
}

mock_fetch_last_json() {
  # Usage: mock_fetch_last_json <out_file> <fetch_last_n>
  local out_file="$1"
  local fetch_n="$2"
  local url sent_count user_text user_hash user_sig
  local assistant_text assistant_hash assistant_len assistant_sig assistant_after
  local chat_id checkpoint_id ts ui_contract
  if ! mock_maybe_fail; then
    return $?
  fi
  url="$(mock_capture_chat_url | tail -n 1)"
  sent_count="$(mock_read_sent_count)"
  if (( sent_count > 0 )); then
    user_text="$PROMPT"
    user_hash="$(printf '%s' "$PROMPT" | stable_hash)"
    user_sig="$(text_signature "$PROMPT")"
    assistant_text="$(mock_peek_reply)"
    assistant_hash="$(printf '%s' "$assistant_text" | stable_hash)"
    assistant_len="$(printf '%s' "$assistant_text" | wc -c | tr -d ' ')"
    assistant_sig="$(text_signature "$assistant_text")"
    assistant_after=1
  else
    user_text=""
    user_hash=""
    user_sig=""
    assistant_text=""
    assistant_hash=""
    assistant_len=0
    assistant_sig=""
    assistant_after=0
  fi
  chat_id="$(chat_id_from_url "$url" 2>/dev/null || true)"
  checkpoint_id="SPC-$(date -u +%Y-%m-%dT%H:%M:%SZ)-${assistant_hash:0:8}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ui_contract="schema=v1|composer=1|send=1|stop=0|assistant_after_anchor=${assistant_after}"
  python3 - "$out_file" "$url" "$chat_id" "$fetch_n" "$assistant_after" "$user_text" "$user_hash" "$user_sig" "$assistant_text" "$assistant_hash" "$assistant_len" "$assistant_sig" "$checkpoint_id" "$ts" "$ui_contract" <<'PY'
import json
import sys

(
    out_file,
    url,
    chat_id,
    fetch_n,
    assistant_after,
    user_text,
    user_hash,
    user_sig,
    assistant_text,
    assistant_hash,
    assistant_len,
    assistant_sig,
    checkpoint_id,
    ts,
    ui_contract,
) = sys.argv[1:]

assistant_after_i = int(assistant_after or 0)
assistant_len_i = int(assistant_len or 0)
messages = []
if user_text:
    messages.append({"role": "user", "text": user_text, "sig": user_sig, "text_len": len(user_text)})
if assistant_text:
    messages.append({"role": "assistant", "text": assistant_text, "sig": assistant_sig, "text_len": len(assistant_text)})
payload = {
    "url": url,
    "chat_id": chat_id,
    "stop_visible": False,
    "total_messages": len(messages),
    "limit": int(fetch_n or 6),
    "assistant_after_last_user": bool(assistant_after_i),
    "last_user_text": user_text,
    "last_user_text_sig": user_sig,
    "last_user_sig": user_sig,
    "last_user_hash": user_hash,
    "assistant_text": assistant_text,
    "assistant_text_sig": assistant_sig,
    "last_assistant_sig": assistant_sig,
    "assistant_tail_hash": assistant_hash,
    "assistant_tail_len": assistant_len_i,
    "assistant_preview": assistant_text[:220],
    "user_tail_hash": user_hash,
    "ui_state": "ok",
    "ui_contract_sig": ui_contract,
    "fingerprint_v1": "mock-fingerprint-v1",
    "norm_version": "v1",
    "checkpoint_id": checkpoint_id,
    "ts": ts,
    "messages": messages,
}
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
PY
  echo "[mock] fetch_last n=${fetch_n} url=${url} sent_count=${sent_count} run_id=${RUN_ID}" >&2
}
