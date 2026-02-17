#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"
LOG_FILE="${1:-/tmp/T_e2e_home_probe_no_active_switch.log}"

RUN_ID="homeprobe-$(date +%s)-$$"
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state/runs/${RUN_ID}"
mkdir -p "$RUN_DIR"

export CHATGPT_SEND_RUN_ID="$RUN_ID"
export CHATGPT_SEND_LOG_DIR="$RUN_DIR"
export CHATGPT_SEND_SKIP_PRECHECK=1
export CHATGPT_SEND_MAX_CDP_SLOTS=1
export CHATGPT_SEND_HOME_REUSES_ACTIVE=0
export CHATGPT_SEND_ALLOW_HOME_SEND=1

if ! curl -fsS "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
  echo "SKIP_CDP_DOWN"
  echo "T_e2e_home_probe_no_active_switch: SKIP (cdp preflight failed)"
  exit 2
fi

read_active_stable() {
  local active=""
  local i
  for i in 1 2 3; do
    doctor="$("$SCRIPT" --doctor 2>/dev/null || true)"
    candidate="$(echo "$doctor" | sed -n 's/^  active_session: //p' | head -n 1)"
    if [[ -n "${candidate:-}" ]]; then
      active="$candidate"
    fi
    sleep 0.2
  done
  printf '%s\n' "$active"
}

before_active="$(read_active_stable)"
if [[ -z "${before_active:-}" || "$before_active" == "(none)" ]]; then
  echo "SKIP_NO_ACTIVE_SESSION"
  echo "T_e2e_home_probe_no_active_switch: SKIP (no active session)"
  exit 2
fi

prompt="T_e2e_home_probe_no_active_switch $(date +%s)"

set +e
PRINT_URL=1 CHATGPT_SEND_CDP_RECOVER_BUDGET=2 "$SCRIPT" \
  --chatgpt-url "https://chatgpt.com/" \
  --prompt "$prompt" >"$LOG_FILE" 2>&1
st=$?
set -e
if [[ "$st" -ne 0 ]]; then
  if rg -q "Timed out waiting for ChatGPT composer to be ready|chatgpt_send failed \\(cdp status=4\\)" "$LOG_FILE"; then
    echo "SKIP_COMPOSER_TIMEOUT"
    echo "T_e2e_home_probe_no_active_switch: SKIP (transient composer timeout)"
    echo "log: $LOG_FILE"
    exit 2
  fi
  echo "target command failed with exit=$st; log=$LOG_FILE" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit "$st"
fi

after_active="$(read_active_stable)"

if [[ "${before_active}" != "${after_active}" ]]; then
  echo "active session changed unexpectedly: before=${before_active} after=${after_active}" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
fi

if ! rg -q "\[P2\] active_update=skipped reason=explicit_home_probe" "$LOG_FILE"; then
  echo "missing explicit-home skip marker in log: $LOG_FILE" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
  exit 1
fi

echo "T_e2e_home_probe_no_active_switch: OK"
echo "log: $LOG_FILE"
