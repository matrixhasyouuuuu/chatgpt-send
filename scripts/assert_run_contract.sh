#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/assert_run_contract.sh --log PATH --expect EXPECT

EXPECT values:
  PASS
  BLOCK_ROUTE
  BROWSER_DOWN_FAIL
  REUSE
EOF
}

LOG_PATH=""
EXPECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG_PATH="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${LOG_PATH:-}" ]] || { echo "--log is required" >&2; exit 2; }
[[ -n "${EXPECT:-}" ]] || { echo "--expect is required" >&2; exit 2; }
[[ -f "$LOG_PATH" ]] || { echo "Log not found: $LOG_PATH" >&2; exit 2; }

rg -q 'PROTO_ENFORCE fingerprint=1 postsend_verify=1 strict_single_chat=1' "$LOG_PATH" \
  || { echo "E_PROTO_ENFORCEMENT_NOT_ENABLED" >&2; exit 1; }
rg -q 'TAB_HYGIENE_ENFORCE auto_tab_hygiene=1' "$LOG_PATH" \
  || { echo "E_TAB_HYGIENE_NOT_ENABLED" >&2; exit 1; }

has_send_dispatch=0
if rg -q 'phase=send event=dispatched|action=send' "$LOG_PATH"; then
  has_send_dispatch=1
fi

case "$EXPECT" in
  PASS)
    rg -q 'SEND_START' "$LOG_PATH"
    rg -q 'POSTSEND_VERIFY .*result=OK' "$LOG_PATH"
    rg -q 'REPLY_READY|REUSE_EXISTING|REPLY_WAIT done outcome=ready' "$LOG_PATH"
    ;;
  BLOCK_ROUTE)
    rg -q 'E_ROUTE_MISMATCH|E_MULTIPLE_CHAT_TABS_BLOCKED|CHAT_ROUTE=E_ROUTE_MISMATCH' "$LOG_PATH"
    if [[ "$has_send_dispatch" -eq 1 ]]; then
      echo "Unexpected dispatch in BLOCK_ROUTE scenario" >&2
      exit 1
    fi
    ;;
  BROWSER_DOWN_FAIL)
    rg -q 'E_CDP_UNREACHABLE|E_BROWSER_DOWN|CDP is not reachable|E_CDP_RECOVER_BUDGET_EXCEEDED' "$LOG_PATH"
    ;;
  REUSE)
    rg -q 'REUSE_EXISTING|LEDGER_PENDING_AUTO_HEAL done outcome=ready' "$LOG_PATH"
    if [[ "$has_send_dispatch" -eq 1 ]]; then
      echo "Unexpected dispatch in REUSE scenario" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported --expect: $EXPECT" >&2
    exit 2
    ;;
esac

echo "ASSERT_OK expect=$EXPECT log=$LOG_PATH"
