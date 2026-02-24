#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/state"

run_live="${RUN_LIVE_CDP_E2E:-0}"
cdp_port="${CHATGPT_SEND_CDP_PORT:-9222}"
transport="${CHATGPT_SEND_TRANSPORT:-cdp}"
allow_work_chat="${ALLOW_WORK_CHAT_FOR_LIVE:-0}"
live_concurrency="${LIVE_CONCURRENCY:-2}"
live_chat_pool_file="${LIVE_CHAT_POOL_FILE:-}"
live_chat_pool_precheck="${LIVE_CHAT_POOL_PRECHECK:-auto}"
chat_pool_manage="$ROOT_DIR/scripts/chat_pool_manage.sh"
chat_pool_precheck_script="$ROOT_DIR/scripts/live_chat_pool_precheck.sh"
ok_cdp=0
ok_work_chat=0
ok_e2e_chat=0
ok_chat_pool=0
chat_pool_count=0
ok_chat_pool_precheck=1
chat_pool_precheck_status="skipped"
chat_pool_precheck_summary_json="none"
chat_pool_precheck_jsonl="none"
ok_locks=1
lock_in_use=0
stale_pid=0
work_chat_url=""
e2e_chat_url=""
live_chat_url=""
live_chat_source="none"
pool_first_url=""
cdp_version_json=""
lock_file="${CHATGPT_SEND_LOCK_FILE:-/tmp/chatgpt-send-shared-browser.lock}"
reason=""

if [[ ! "$live_concurrency" =~ ^[0-9]+$ ]] || (( live_concurrency < 1 )); then
  echo "invalid LIVE_CONCURRENCY: $live_concurrency" >&2
  exit 2
fi
if [[ ! "$transport" =~ ^(cdp|mock)$ ]]; then
  echo "invalid CHATGPT_SEND_TRANSPORT: $transport" >&2
  exit 2
fi
if [[ ! "$live_chat_pool_precheck" =~ ^(0|1|auto)$ ]]; then
  echo "invalid LIVE_CHAT_POOL_PRECHECK: $live_chat_pool_precheck (expected 0|1|auto)" >&2
  exit 2
fi

if [[ "$transport" == "mock" ]]; then
  ok_cdp=1
  cdp_version_json='{"Browser":"mock"}'
else
  if cdp_version_json="$(curl -fsS --max-time 3 "http://127.0.0.1:${cdp_port}/json/version" 2>/dev/null)"; then
    ok_cdp=1
  else
    ok_cdp=0
  fi
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

if [[ -n "$live_chat_pool_file" ]]; then
  if [[ ! -x "$chat_pool_manage" ]]; then
    echo "chat pool manager not executable: $chat_pool_manage" >&2
    exit 15
  fi
  set +e
  pool_validate_out="$("$chat_pool_manage" validate --chat-pool-file "$live_chat_pool_file" --min "$live_concurrency" 2>&1)"
  pool_validate_rc=$?
  set -e
  echo "$pool_validate_out"
  if [[ "$pool_validate_rc" != "0" ]]; then
    exit 15
  fi
  ok_chat_pool=1
  chat_pool_count="$(printf '%s\n' "$pool_validate_out" | sed -n 's/^CHAT_POOL_COUNT=//p' | tail -n 1)"
  if [[ ! "$chat_pool_count" =~ ^[0-9]+$ ]]; then
    chat_pool_count=0
  fi
  pool_first_url="$(sed -e 's/\r$//' "$live_chat_pool_file" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | sed -n '1p' | xargs || true)"
elif [[ "$run_live" == "1" ]] && (( live_concurrency >= 5 )); then
  echo "E_CHAT_POOL_REQUIRED_FOR_SCALE concurrency=$live_concurrency"
  exit 15
fi

echo "RUN_LIVE_CDP_E2E=$run_live"
echo "CDP_PORT=$cdp_port"
echo "CHATGPT_SEND_TRANSPORT=$transport"
echo "LIVE_CONCURRENCY=$live_concurrency"
echo "LIVE_CHAT_POOL_FILE=${live_chat_pool_file:-none}"
echo "LIVE_CHAT_POOL_PRECHECK=$live_chat_pool_precheck"
echo "ALLOW_WORK_CHAT_FOR_LIVE=$allow_work_chat"
echo "OK_CDP=$ok_cdp"
echo "OK_E2E_CHAT_URL=$ok_e2e_chat"
echo "E2E_CHAT_URL=${e2e_chat_url:-none}"
echo "OK_WORK_CHAT_URL=$ok_work_chat"
echo "WORK_CHAT_URL=${work_chat_url:-none}"
echo "OK_CHAT_POOL=$ok_chat_pool"
echo "CHAT_POOL_COUNT=$chat_pool_count"
echo "OK_LOCKS=$ok_locks"
echo "LOCK_FILE=$lock_file"
echo "LOCK_IN_USE=$lock_in_use"
echo "STALE_PID=$stale_pid"
if [[ -n "$reason" ]]; then
  echo "LOCK_REASON=$reason"
fi
if [[ "$ok_cdp" == "1" ]]; then
  browser_field="$(python3 -c '
import json,sys
try:
    obj=json.loads(sys.stdin.read())
except Exception:
    print("none")
    raise SystemExit(0)
print(obj.get("Browser","none"))
' <<<"$cdp_version_json")"
  echo "CDP_BROWSER=${browser_field:-none}"
fi

if [[ "$ok_cdp" != "1" ]]; then
  exit 10
fi
if [[ "$ok_locks" != "1" ]]; then
  exit 12
fi

run_pool_precheck=0
if [[ "$live_chat_pool_precheck" == "1" ]]; then
  run_pool_precheck=1
elif [[ "$live_chat_pool_precheck" == "auto" ]] && [[ "$run_live" == "1" ]] && (( live_concurrency >= 5 )); then
  run_pool_precheck=1
fi

if (( run_pool_precheck == 1 )) && [[ "$ok_chat_pool" == "1" ]]; then
  if [[ ! -x "$chat_pool_precheck_script" ]]; then
    echo "chat pool precheck script not executable: $chat_pool_precheck_script" >&2
    exit 16
  fi
  precheck_stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
  chat_pool_precheck_jsonl="$STATE_DIR/precheck/live_chat_pool_precheck_${precheck_stamp}.jsonl"
  chat_pool_precheck_summary_json="$STATE_DIR/precheck/live_chat_pool_precheck_${precheck_stamp}.summary.json"
  set +e
  pool_precheck_out="$(
    bash "$chat_pool_precheck_script" \
      --chat-pool-file "$live_chat_pool_file" \
      --concurrency "$live_concurrency" \
      --chatgpt-send "$ROOT_DIR/bin/chatgpt_send" \
      --transport "$transport" \
      --out-jsonl "$chat_pool_precheck_jsonl" \
      --out-summary-json "$chat_pool_precheck_summary_json" 2>&1
  )"
  pool_precheck_rc=$?
  set -e
  echo "$pool_precheck_out"
  if [[ "$pool_precheck_rc" == "0" ]]; then
    ok_chat_pool_precheck=1
    chat_pool_precheck_status="ok"
  else
    ok_chat_pool_precheck=0
    chat_pool_precheck_status="fail"
    echo "OK_CHAT_POOL_PRECHECK=$ok_chat_pool_precheck"
    echo "CHAT_POOL_PRECHECK_STATUS=$chat_pool_precheck_status"
    echo "CHAT_POOL_PRECHECK_SUMMARY_JSON=$chat_pool_precheck_summary_json"
    echo "CHAT_POOL_PRECHECK_JSONL=$chat_pool_precheck_jsonl"
    echo "E_CHAT_POOL_PRECHECK_FAILED rc=$pool_precheck_rc"
    exit 16
  fi
fi

echo "OK_CHAT_POOL_PRECHECK=$ok_chat_pool_precheck"
echo "CHAT_POOL_PRECHECK_STATUS=$chat_pool_precheck_status"
echo "CHAT_POOL_PRECHECK_SUMMARY_JSON=$chat_pool_precheck_summary_json"
echo "CHAT_POOL_PRECHECK_JSONL=$chat_pool_precheck_jsonl"

if [[ "$ok_e2e_chat" == "1" ]]; then
  live_chat_url="$e2e_chat_url"
  live_chat_source="e2e"
elif [[ "$allow_work_chat" == "1" ]] && [[ "$ok_work_chat" == "1" ]]; then
  live_chat_url="$work_chat_url"
  live_chat_source="work_fallback"
  echo "W_E2E_CHAT_MISSING_FALLBACK_TO_WORK=1"
elif [[ "$ok_chat_pool" == "1" ]] && [[ "$pool_first_url" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
  live_chat_url="$pool_first_url"
  live_chat_source="pool_fallback"
elif [[ "$allow_work_chat" == "1" ]] && [[ "$ok_work_chat" != "1" ]]; then
  exit 11
else
  exit 14
fi

echo "LIVE_CHAT_SOURCE=$live_chat_source"
echo "LIVE_CHAT_URL=$live_chat_url"

exit 0
