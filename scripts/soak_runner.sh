#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERS=200
RUN_ID=""
CHATGPT_SEND_BIN="${CHATGPT_SEND_BIN:-$ROOT/bin/chatgpt_send}"
PROMPT_PREFIX="soak"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iters)
      ITERS="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --chatgpt-send-bin)
      CHATGPT_SEND_BIN="${2:-}"
      shift 2
      ;;
    --prompt-prefix)
      PROMPT_PREFIX="${2:-soak}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${RUN_ID//[[:space:]]/}" ]]; then
  RUN_ID="soak-$(date +%s)-$RANDOM"
fi
if [[ ! "$ITERS" =~ ^[0-9]+$ ]] || (( ITERS < 1 )); then
  echo "--iters must be a positive integer" >&2
  exit 2
fi
if [[ ! -x "$CHATGPT_SEND_BIN" ]]; then
  echo "chatgpt_send binary not executable: $CHATGPT_SEND_BIN" >&2
  exit 2
fi

RUN_DIR="$ROOT/state/runs/$RUN_ID"
SOAK_DIR="$RUN_DIR/soak"
SOAK_LOG="$SOAK_DIR/soak.log"
SUMMARY_FILE="$SOAK_DIR/summary.txt"
CHECK_LOG="$SOAK_DIR/gate_check.log"
RUNTIME_ROOT="$RUN_DIR/runtime_root"

mkdir -p "$SOAK_DIR"
mkdir -p "$RUNTIME_ROOT/state"
ln -sfn "$ROOT/bin" "$RUNTIME_ROOT/bin"
ln -sfn "$ROOT/docs" "$RUNTIME_ROOT/docs"
export CHATGPT_SEND_ROOT="$RUNTIME_ROOT"
export CHATGPT_SEND_PROFILE_DIR="${CHATGPT_SEND_PROFILE_DIR:-$ROOT/state/manual-login-profile}"
export CHATGPT_SEND_RUN_ID="$RUN_ID"
export CHATGPT_SEND_LOG_DIR="$RUN_DIR"

failed=0
skipped=0

echo "RUN_ID=$RUN_ID" | tee "$SUMMARY_FILE"
echo "profile=soak" | tee -a "$SUMMARY_FILE"
echo "soak_iters=$ITERS" | tee -a "$SUMMARY_FILE"
echo "chatgpt_send_bin=$CHATGPT_SEND_BIN" | tee -a "$SUMMARY_FILE"
echo "runtime_root=$RUNTIME_ROOT" | tee -a "$SUMMARY_FILE"

for ((i=1; i<=ITERS; i++)); do
  prompt="${PROMPT_PREFIX} iter ${i}/${ITERS} run_id=${RUN_ID}"
  echo "[SOAK] iter=$i/$ITERS action=send" >>"$SOAK_LOG"
  set +e
  "$CHATGPT_SEND_BIN" --prompt "$prompt" >>"$SOAK_LOG" 2>&1
  st=$?
  set -e
  echo "[SOAK] iter=$i/$ITERS status=$st" >>"$SOAK_LOG"
  if [[ "$st" -eq 2 ]]; then
    skipped=$((skipped+1))
  elif [[ "$st" -ne 0 ]]; then
    failed=$((failed+1))
  fi
done

echo "tests_skipped=$skipped" | tee -a "$SUMMARY_FILE"
echo "soak_failed=$failed" | tee -a "$SUMMARY_FILE"

set +e
"$ROOT/scripts/release_gate_check.sh" --profile soak --run-id "$RUN_ID" >"$CHECK_LOG" 2>&1
check_st=$?
set -e
cat "$CHECK_LOG" | tee -a "$SUMMARY_FILE"
echo "check_status=$check_st" | tee -a "$SUMMARY_FILE"

if [[ "$failed" -ne 0 ]] || [[ "$check_st" -ne 0 ]]; then
  exit 1
fi
exit 0
