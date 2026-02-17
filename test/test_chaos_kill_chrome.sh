#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${1:-$ROOT/state/golden/T_chaos_kill_chrome.log}"

if [[ "${CHATGPT_SEND_RUN_LIVE_CHAOS:-0}" != "1" ]]; then
  echo "T_chaos_kill_chrome: SKIP (set CHATGPT_SEND_RUN_LIVE_CHAOS=1)"
  exit 0
fi

doctor="$("$SCRIPT" --doctor 2>/dev/null || true)"
if ! echo "$doctor" | rg -q "cdp: OK"; then
  echo "T_chaos_kill_chrome: SKIP (cdp is not ready)"
  exit 0
fi

target_url="$(echo "$doctor" | sed -n 's/^  pinned_url: //p' | head -n 1)"
if [[ -z "${target_url:-}" ]] || [[ ! "$target_url" =~ ^https://chatgpt\.com/c/ ]]; then
  echo "T_chaos_kill_chrome: SKIP (no pinned /c/ url)"
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")"

"$SCRIPT" --open-browser --chatgpt-url "$target_url" >/dev/null 2>&1 || true

prompt="T_chaos_kill_chrome $(date +%s)"
set +e
CHATGPT_SEND_CDP_RECOVER_BUDGET=1 \
CHATGPT_SEND_CDP_RECOVER_COOLDOWN_SEC=2 \
"$SCRIPT" --chatgpt-url "$target_url" --prompt "$prompt" >"$LOG_FILE" 2>&1 &
runner_pid=$!
set -e

# Give CDP flow a moment to start, then kill automation Chrome once.
sleep 1
profile_dir="$ROOT/state/manual-login-profile"
pids="$(ps -eo pid=,args= | awk -v p="$profile_dir" '$0 ~ "--user-data-dir="p {print $1}')"
if [[ -n "${pids//[[:space:]]/}" ]]; then
  while read -r p; do
    [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true
  done <<< "$pids"
fi

set +e
wait "$runner_pid"
st=$?
set -e

recover_count="$(rg -c --fixed-strings "[P4] cdp_recover single_flight" "$LOG_FILE" || true)"
used_count="$(rg -c --fixed-strings "[P4] cdp_recover used=" "$LOG_FILE" || true)"

if [[ "$recover_count" -ne 1 ]]; then
  echo "expected exactly 1 recover marker, got $recover_count" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
fi
if [[ "$used_count" -ne 1 ]]; then
  echo "expected exactly 1 recover-used marker, got $used_count" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
fi

if [[ "$st" -eq 0 ]]; then
  echo "T_chaos_kill_chrome: OK (recovered)"
  echo "log: $LOG_FILE"
  exit 0
fi

# Clean fail is acceptable if we got explicit marker and no silent success.
if rg -q "chatgpt_send failed \(cdp status=" "$LOG_FILE" && rg -q "E_CDP_RECOVER_BUDGET_EXCEEDED|E_CDP_UNREACHABLE.recover_once|E_ACTIVITY_TIMEOUT" "$LOG_FILE"; then
  echo "T_chaos_kill_chrome: OK (clean fail)"
  echo "log: $LOG_FILE"
  exit 0
fi

echo "unexpected failure mode (status=$st)" >&2
tail -n 120 "$LOG_FILE" >&2 || true
exit 1
