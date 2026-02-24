# shellcheck shell=bash
# Argument parsing for chatgpt_send main flow.
chatgpt_send_parse_args() {
while [[ $# -gt 0 ]]; do
  case "$1" in
    step)
      DO_STEP=1
      if [[ $# -ge 2 ]] && [[ "${2:-}" != --* ]]; then
        STEP_ACTION="$2"; shift 2
      else
        STEP_ACTION="auto"; shift
      fi
      ;;
    --prompt) PROMPT="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --model-strategy) MODEL_STRATEGY="$2"; shift 2;;
    --keep-browser) KEEP_BROWSER=1; shift;;
    --no-keep-browser) KEEP_BROWSER=0; shift;;
    --manual-login) MANUAL_LOGIN=1; shift;;
    --no-manual-login) MANUAL_LOGIN=0; shift;;
    --chrome-path) CHROME_PATH="$2"; shift 2;;
    --chatgpt-url) CHATGPT_URL="$2"; CHATGPT_URL_EXPLICIT=1; shift 2;;
    --chat-id) CHATGPT_URL="https://chatgpt.com/c/$2"; CHATGPT_URL_EXPLICIT=1; shift 2;;
    --transport) CHATGPT_SEND_TRANSPORT="$2"; shift 2;;
    --probe-chat-url) PROBE_CHAT_URL="$2"; shift 2;;
    --no-state-write) SKIP_STATE_WRITE=1; shift;;
    --init-specialist) INIT_SPECIALIST=1; shift;;
    --topic) INIT_TOPIC="$2"; shift 2;;
    --set-active-title) SET_ACTIVE_TITLE="$2"; shift 2;;
    --open-browser) OPEN_BROWSER=1; shift;;
    --sync-chatgpt-url) SYNC_URL=1; shift;;
    --print-chatgpt-url) PRINT_URL=1; shift;;
    --cdp-port) CDP_PORT="$2"; shift 2;;
    --list-chats) LIST_CHATS=1; shift;;
    --status) DO_STATUS=1; shift;;
    --explain)
      DO_EXPLAIN=1
      if [[ $# -ge 2 ]] && [[ "${2:-}" != --* ]]; then
        EXPLAIN_TARGET="$2"; shift 2
      else
        EXPLAIN_TARGET="latest"; shift
      fi
      ;;
    --step) DO_STEP=1; shift;;
    --action) STEP_ACTION="$2"; shift 2;;
    --message) STEP_MESSAGE="$2"; shift 2;;
    --max-steps) STEP_MAX_STEPS="$2"; shift 2;;
    --until) STEP_UNTIL="$2"; shift 2;;
    --doctor) DOCTOR=1; shift;;
    --json) OUTPUT_JSON=1; DOCTOR_JSON=1; shift;;
    --cleanup) DO_CLEANUP=1; shift;;
    --graceful-restart-browser) DO_GRACEFUL_RESTART=1; shift;;
    --ack) DO_ACK=1; shift;;
    --save-chat) SAVE_CHAT_NAME="$2"; shift 2;;
    --use-chat) USE_CHAT_NAME="$2"; shift 2;;
    --delete-chat) DELETE_CHAT_NAME="$2"; shift 2;;
    --bundle) BUNDLE_RUN_ID="$2"; shift 2;;
    --loop-init) LOOP_INIT="$2"; shift 2;;
    --loop-status) LOOP_STATUS=1; shift;;
    --loop-inc) LOOP_INC=1; shift;;
    --loop-clear) LOOP_CLEAR=1; shift;;
    --set-chatgpt-url)
      mkdir -p "$(dirname "$CHATGPT_URL_FILE")" >/dev/null 2>&1 || true
      url="$2"
      # If the user tries to set a /c/... URL, enforce validity (prevents saving garbage like /c/test-loop).
      if [[ "$url" =~ ^https://chatgpt\.com/c/ ]] && ! is_chat_conversation_url "$url"; then
        echo "Error: invalid ChatGPT conversation URL: $url" >&2
        exit 2
      fi
      if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && is_chat_conversation_url "${PROTECT_CHAT_URL}" \
        && [[ "$url" != "${PROTECT_CHAT_URL}" ]]; then
        emit_protect_chat_mismatch "${PROTECT_CHAT_URL}" "$url"
      fi

      printf '%s\n' "$url" >"$CHATGPT_URL_FILE"

      # Persist as a Specialist session only when it's a conversation URL.
      if is_chat_conversation_url "$url"; then
        write_work_chat_url "$url"
        chats_db_upsert "last" "$url" "" >/dev/null 2>&1 || true
        chats_db_set_active "last" >/dev/null 2>&1 || true
      else
        rm -f "$WORK_CHAT_URL_FILE" >/dev/null 2>&1 || true
      fi

      echo "Saved default ChatGPT URL: $url" >&2
      exit 0
      ;;
    --clear-chatgpt-url)
      rm -f "$CHATGPT_URL_FILE"
      rm -f "$WORK_CHAT_URL_FILE"
      echo "Cleared default ChatGPT URL." >&2
      exit 0
      ;;
    --show-chatgpt-url)
      work_url="$(read_work_chat_url || true)"
      if [[ -n "${work_url:-}" ]]; then
        echo "$work_url"
        exit 0
      fi
      if [[ -f "$CHATGPT_URL_FILE" ]]; then
        cat "$CHATGPT_URL_FILE"
        exit 0
      fi
      if [[ -n "${CHATGPT_URL_DEFAULT:-}" ]]; then
        echo "$CHATGPT_URL_DEFAULT"
        exit 0
      fi
      if cdp_is_up; then
        tab="$(capture_best_chat_tab_from_cdp || true)"
        detected="${tab%%$'\t'*}"
        if [[ -n "${detected:-}" ]] && [[ "$detected" != "$tab" ]] && is_chat_conversation_url "$detected"; then
          echo "$detected"
          exit 0
        fi
      fi
      echo ""  # empty means "no default"
      exit 0
      ;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --attach) ATTACH+=("$2"); shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done
}
