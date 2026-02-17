#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE=""
FAULT=""
ITER=""
CHAT_URL=""
ALLOW_DESTRUCTIVE="${CHATGPT_SEND_STRESS_ALLOW_DESTRUCTIVE:-0}"
CDP_PORT="${CHATGPT_SEND_CDP_PORT:-9222}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --fault) FAULT="$2"; shift 2 ;;
    --iter) ITER="$2"; shift 2 ;;
    --chat-url) CHAT_URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${PHASE:-}" ]] || { echo "missing --phase"; exit 2; }
[[ -n "${FAULT:-}" ]] || { echo "missing --fault"; exit 2; }

echo "FAULT_HOOK phase=${PHASE} iter=${ITER:-0} fault=${FAULT} allow_destructive=${ALLOW_DESTRUCTIVE}"

if [[ "$PHASE" != "pre" ]]; then
  exit 0
fi

case "$FAULT" in
  none|stop_visible_pre|tight_timeout_pre|interrupt_after_dispatch)
    echo "FAULT_APPLY skipped fault=${FAULT} reason=manual_or_not_implemented"
    ;;
  browser_down_pre)
    if [[ "$ALLOW_DESTRUCTIVE" == "1" ]]; then
      "$ROOT/bin/chatgpt_send" --cleanup >/dev/null 2>&1 || true
      echo "FAULT_APPLY ok fault=browser_down_pre action=cleanup"
    else
      echo "FAULT_APPLY skipped fault=browser_down_pre reason=allow_destructive=0"
    fi
    ;;
  browser_up_pre)
    "$ROOT/bin/chatgpt_send" --open-browser --chatgpt-url "${CHAT_URL:-https://chatgpt.com/}" >/dev/null 2>&1 || true
    echo "FAULT_APPLY ok fault=browser_up_pre action=open_browser"
    ;;
  browser_restart_pre)
    if [[ "$ALLOW_DESTRUCTIVE" == "1" ]]; then
      "$ROOT/bin/chatgpt_send" --cleanup >/dev/null 2>&1 || true
    fi
    "$ROOT/bin/chatgpt_send" --open-browser --chatgpt-url "${CHAT_URL:-https://chatgpt.com/}" >/dev/null 2>&1 || true
    echo "FAULT_APPLY ok fault=browser_restart_pre action=restart_browser"
    ;;
  wrong_tab_pre|route_switch_pre)
    set +e
    curl -fsS -X PUT "http://127.0.0.1:${CDP_PORT}/json/new?https://chatgpt.com/" >/dev/null 2>&1
    st=$?
    set -e
    if [[ $st -eq 0 ]]; then
      echo "FAULT_APPLY ok fault=${FAULT} action=open_extra_chatgpt_tab"
    else
      echo "FAULT_APPLY skipped fault=${FAULT} reason=cdp_new_tab_failed"
    fi
    ;;
  route_restore_pre)
    echo "FAULT_APPLY skipped fault=route_restore_pre reason=auto_route_guard"
    ;;
  corrupt_ledger_last_line_pre)
    printf '%s\n' '{"broken_json_line":' >>"$ROOT/state/protocol.jsonl"
    echo "FAULT_APPLY ok fault=corrupt_ledger_last_line_pre action=append_broken_json"
    ;;
  *)
    echo "FAULT_APPLY skipped fault=${FAULT} reason=unknown_fault"
    ;;
esac
