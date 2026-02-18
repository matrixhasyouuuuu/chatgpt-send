#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/state"

run_live="${RUN_LIVE_CDP_E2E:-0}"
cdp_port="${CHATGPT_SEND_CDP_PORT:-9222}"
allow_work_chat="${ALLOW_WORK_CHAT_FOR_LIVE:-0}"
ok_cdp=0
ok_work_chat=0
ok_e2e_chat=0
ok_locks=1
lock_in_use=0
stale_pid=0
work_chat_url=""
e2e_chat_url=""
live_chat_url=""
live_chat_source="none"
cdp_version_json=""
lock_file="${CHATGPT_SEND_LOCK_FILE:-/tmp/chatgpt-send-shared-browser.lock}"
reason=""

if cdp_version_json="$(curl -fsS --max-time 3 "http://127.0.0.1:${cdp_port}/json/version" 2>/dev/null)"; then
  ok_cdp=1
else
  ok_cdp=0
fi

if [[ -f "$STATE_DIR/chatgpt_url_e2e.txt" ]]; then
  candidate="$(sed -n '1p' "$STATE_DIR/chatgpt_url_e2e.txt" | tr -d '\r' | xargs || true)"
  if [[ "$candidate" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
    e2e_chat_url="$candidate"
    ok_e2e_chat=1
  fi
fi

for path in "$STATE_DIR/chatgpt_url.txt" "$STATE_DIR/work_chat_url.txt"; do
  if [[ -f "$path" ]]; then
    candidate="$(sed -n '1p' "$path" | tr -d '\r' | xargs || true)"
    if [[ "$candidate" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
      work_chat_url="$candidate"
      ok_work_chat=1
      break
    fi
  fi
done

if [[ -e "$lock_file" ]]; then
  if command -v fuser >/dev/null 2>&1; then
    if fuser "$lock_file" >/dev/null 2>&1; then
      lock_in_use=1
    fi
  fi
fi

pid_file="$STATE_DIR/chrome_${cdp_port}.pid"
if [[ -f "$pid_file" ]]; then
  pid="$(tr -d '[:space:]' <"$pid_file" || true)"
  if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      stale_pid=1
    fi
  fi
fi

if [[ "$stale_pid" == "1" ]] && [[ "$lock_in_use" == "0" ]]; then
  ok_locks=0
  reason="stale_pid_without_lock_holder"
fi

echo "RUN_LIVE_CDP_E2E=$run_live"
echo "CDP_PORT=$cdp_port"
echo "ALLOW_WORK_CHAT_FOR_LIVE=$allow_work_chat"
echo "OK_CDP=$ok_cdp"
echo "OK_E2E_CHAT_URL=$ok_e2e_chat"
echo "E2E_CHAT_URL=${e2e_chat_url:-none}"
echo "OK_WORK_CHAT_URL=$ok_work_chat"
echo "WORK_CHAT_URL=${work_chat_url:-none}"
echo "OK_LOCKS=$ok_locks"
echo "LOCK_FILE=$lock_file"
echo "LOCK_IN_USE=$lock_in_use"
echo "STALE_PID=$stale_pid"
if [[ -n "$reason" ]]; then
  echo "LOCK_REASON=$reason"
fi
if [[ "$ok_cdp" == "1" ]]; then
  browser_field="$(printf '%s' "$cdp_version_json" | python3 - <<'PY'
import json,sys
try:
    obj=json.load(sys.stdin)
except Exception:
    print("none")
    raise SystemExit(0)
print(obj.get("Browser","none"))
PY
)"
  echo "CDP_BROWSER=${browser_field:-none}"
fi

if [[ "$ok_cdp" != "1" ]]; then
  exit 10
fi
if [[ "$ok_locks" != "1" ]]; then
  exit 12
fi

if [[ "$ok_e2e_chat" == "1" ]]; then
  live_chat_url="$e2e_chat_url"
  live_chat_source="e2e"
elif [[ "$allow_work_chat" == "1" ]] && [[ "$ok_work_chat" == "1" ]]; then
  live_chat_url="$work_chat_url"
  live_chat_source="work_fallback"
  echo "W_E2E_CHAT_MISSING_FALLBACK_TO_WORK=1"
elif [[ "$allow_work_chat" == "1" ]] && [[ "$ok_work_chat" != "1" ]]; then
  exit 11
else
  exit 14
fi

echo "LIVE_CHAT_SOURCE=$live_chat_source"
echo "LIVE_CHAT_URL=$live_chat_url"

exit 0
