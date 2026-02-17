#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_FILE="$ROOT/scripts/stress_plan_v1.json"
ITERS=30
CHAT_URL=""
OUT_DIR="${TMPDIR:-/tmp}/chatgpt_send_stress"
FAULT_HOOK=""
PROMPT_PREFIX="T_stress_interaction"

usage() {
  cat <<'EOF'
Usage:
  scripts/stress_interaction_harness.sh [options]

Options:
  --iters N
  --plan PATH
  --chat-url URL
  --out-dir DIR
  --fault-hook PATH
  --prompt-prefix TEXT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iters) ITERS="$2"; shift 2 ;;
    --plan) PLAN_FILE="$2"; shift 2 ;;
    --chat-url) CHAT_URL="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --fault-hook) FAULT_HOOK="$2"; shift 2 ;;
    --prompt-prefix) PROMPT_PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$ITERS" =~ ^[0-9]+$ ]] || { echo "--iters must be integer" >&2; exit 2; }
(( ITERS > 0 )) || { echo "--iters must be > 0" >&2; exit 2; }
[[ -f "$PLAN_FILE" ]] || { echo "Plan file not found: $PLAN_FILE" >&2; exit 2; }

if [[ -z "${CHAT_URL:-}" ]] && [[ -f "$ROOT/state/work_chat_url.txt" ]]; then
  CHAT_URL="$(head -n 1 "$ROOT/state/work_chat_url.txt" || true)"
fi
[[ -n "${CHAT_URL:-}" ]] || { echo "Missing --chat-url and state/work_chat_url.txt is empty" >&2; exit 2; }

mkdir -p "$OUT_DIR" >/dev/null 2>&1 || true
rm -f "$OUT_DIR"/stress_iter_*.log "$OUT_DIR"/summary.csv >/dev/null 2>&1 || true
# Start each stress run with a fresh checkpoint to avoid stale fingerprint
# mismatches after protocol/fingerprint migrations.
rm -f "$ROOT/state/last_specialist_checkpoint.json" >/dev/null 2>&1 || true

# Stress mode must always run with strict protocol enforcement enabled.
export CHATGPT_SEND_PROTO_ENFORCE_FINGERPRINT=1
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=1
export CHATGPT_SEND_STRICT_SINGLE_CHAT=1
export CHATGPT_SEND_AUTO_TAB_HYGIENE=1
export STRICT_SINGLE_CHAT=1
if [[ "${CHATGPT_SEND_PROTO_ENFORCE_FINGERPRINT}" != "1" ]] \
  || [[ "${CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY}" != "1" ]] \
  || [[ "${CHATGPT_SEND_STRICT_SINGLE_CHAT}" != "1" ]]; then
  echo "E_PROTO_ENFORCEMENT_NOT_ENABLED fingerprint=${CHATGPT_SEND_PROTO_ENFORCE_FINGERPRINT} postsend=${CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY} strict_single_chat=${CHATGPT_SEND_STRICT_SINGLE_CHAT}" >&2
  exit 1
fi

mapfile -t SCENARIOS < <(python3 - "$PLAN_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
items = data.get("scenarios") or []
for i, s in enumerate(items, start=1):
    sid = (s.get("id") or f"S{i:02d}").strip()
    expect = (s.get("expect") or "PASS").strip()
    fault = (s.get("fault") or "none").strip()
    note = (s.get("note") or "").replace("\t", " ").replace("\n", " ").strip()
    print(f"{sid}\t{expect}\t{fault}\t{note}")
PY
)

if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  echo "No scenarios in plan: $PLAN_FILE" >&2
  exit 2
fi

pass_count=0
fail_count=0
unexpected_fail_count=0
summary_csv="$OUT_DIR/summary.csv"
printf '%s\n' "iter,scenario,expect,fault,run_status,assert_status,log" >"$summary_csv"

for ((iter=1; iter<=ITERS; iter++)); do
  idx=$(( (iter - 1) % ${#SCENARIOS[@]} ))
  IFS=$'\t' read -r sid expect fault note <<<"${SCENARIOS[$idx]}"
  run_ts="$(date +%s)"
  log="$OUT_DIR/stress_iter_${iter}_${sid}.log"
  prompt="${PROMPT_PREFIX}_${sid}_${run_ts}"

  {
    echo "RUN_START iter=${iter} scenario=${sid} expect=${expect} fault=${fault} ts=${run_ts}"
    echo "CHAT_TARGET_URL=${CHAT_URL}"
    echo "PROTO_ENFORCE fingerprint=1 postsend_verify=1 strict_single_chat=1"
    echo "TAB_HYGIENE_ENFORCE auto_tab_hygiene=${CHATGPT_SEND_AUTO_TAB_HYGIENE:-0}"
    echo "NOTE=${note}"
  } >"$log"

  if [[ -n "${FAULT_HOOK:-}" ]]; then
    if [[ -x "$FAULT_HOOK" ]]; then
      if ! "$FAULT_HOOK" --phase pre --fault "$fault" --iter "$iter" --chat-url "$CHAT_URL" >>"$log" 2>&1; then
        echo "FAULT_HOOK pre failed iter=${iter} scenario=${sid}" >>"$log"
      fi
    else
      echo "FAULT_HOOK skipped (not executable): ${FAULT_HOOK}" >>"$log"
    fi
  else
    echo "FAULT_HOOK none (fault=${fault})" >>"$log"
  fi

  set +e
  "$ROOT/bin/chatgpt_send" --chatgpt-url "$CHAT_URL" --ack >>"$log" 2>&1
  ack_status=$?
  set -e
  echo "PRE_ACK status=${ack_status}" >>"$log"

  idle_start="$(date +%s)"
  idle_max_sec=120
  idle_status=11
  while true; do
    set +e
    python3 "$ROOT/bin/cdp_chatgpt.py" \
      --cdp-port "${CHATGPT_SEND_CDP_PORT:-9222}" \
      --chatgpt-url "$CHAT_URL" \
      --timeout 900 \
      --prompt "$prompt" \
      --precheck-only >>"$log" 2>&1
    idle_status=$?
    set -e
    if [[ "$idle_status" -ne 11 ]]; then
      break
    fi
    if (( $(date +%s) - idle_start >= idle_max_sec )); then
      break
    fi
    sleep 1
  done
  idle_elapsed=$(( $(date +%s) - idle_start ))
  echo "PRE_IDLE status=${idle_status} elapsed_sec=${idle_elapsed}" >>"$log"

  set +e
  "$ROOT/bin/chatgpt_send" --chatgpt-url "$CHAT_URL" --prompt "$prompt" >>"$log" 2>&1
  run_status=$?
  set -e

  set +e
  "$ROOT/scripts/assert_run_contract.sh" --log "$log" --expect "$expect" >>"$log" 2>&1
  assert_status=$?
  set -e

  if [[ -n "${FAULT_HOOK:-}" ]] && [[ -x "$FAULT_HOOK" ]]; then
    "$FAULT_HOOK" --phase post --fault "$fault" --iter "$iter" --chat-url "$CHAT_URL" >>"$log" 2>&1 || true
  fi

  if [[ $assert_status -eq 0 ]]; then
    pass_count=$((pass_count + 1))
    result="PASS"
  else
    fail_count=$((fail_count + 1))
    result="FAIL"
    unexpected_fail_count=$((unexpected_fail_count + 1))
  fi

  printf '%s\n' "${iter},${sid},${expect},${fault},${run_status},${assert_status},${log}" >>"$summary_csv"
  echo "RUN_END iter=${iter} scenario=${sid} result=${result} run_status=${run_status} assert_status=${assert_status} log=${log}"
done

score_output=""
set +e
score_output="$("$ROOT/scripts/score_stress_run.sh" "$OUT_DIR"/stress_iter_*.log 2>/dev/null)"
score_status=$?
set -e
if [[ $score_status -eq 0 ]] && [[ -n "${score_output:-}" ]]; then
  printf '%s\n' "$score_output"
else
  echo "W_SCORE_UNAVAILABLE out_dir=${OUT_DIR}"
fi

echo "STRESS_SUMMARY pass=${pass_count} fail=${fail_count} unexpected_fail=${unexpected_fail_count} out_dir=${OUT_DIR} summary=${summary_csv}"
if [[ $unexpected_fail_count -ne 0 ]]; then
  exit 1
fi
