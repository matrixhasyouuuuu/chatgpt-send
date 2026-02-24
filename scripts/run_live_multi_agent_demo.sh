#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

LIVE_CONCURRENCY="${LIVE_CONCURRENCY:-2}"
LIVE_CHAT_POOL_FILE="${LIVE_CHAT_POOL_FILE:-}"
LIVE_ITERATIONS="${LIVE_ITERATIONS:-1}"
LIVE_PROJECT_PATH="${LIVE_PROJECT_PATH:-$ROOT_DIR}"
LIVE_DEMO_TASKS_FILE="${LIVE_DEMO_TASKS_FILE:-$ROOT_DIR/scripts/demo_tasks_10.txt}"

print_json_summary() {
  local label="$1"
  local path="$2"
  python3 - "$label" "$path" <<'PY'
import json
import pathlib
import sys

label = sys.argv[1]
path = pathlib.Path(sys.argv[2])
if not path.exists():
    print(f"{label}_RESULT_JSON_MISSING={path}")
    raise SystemExit(1)
obj = json.loads(path.read_text(encoding="utf-8"))
print(f"{label}_RUN_ID={obj.get('run_id','')}")
print(f"{label}_STATUS={obj.get('status','')}")
print(f"{label}_EXIT_CODE={obj.get('exit_code','')}")
print(f"{label}_BROWSER_USED={obj.get('browser_used','')}")
print(f"{label}_DURATION_SEC={obj.get('duration_sec','')}")
PY
}

echo "== LIVE PREFLIGHT =="
preflight_out="$tmp_dir/preflight.out"
set +e
bash "$ROOT_DIR/scripts/live_preflight.sh" >"$preflight_out" 2>&1
preflight_rc=$?
set -e
cat "$preflight_out"
if [[ "$preflight_rc" != "0" ]]; then
  echo "DEMO_STATUS=PRECHECK_FAIL"
  echo "DEMO_PRECHECK_EXIT=$preflight_rc"
  exit "$preflight_rc"
fi

export RUN_LIVE_CDP_E2E=1
LIVE_CHAT_URL="$(sed -n 's/^LIVE_CHAT_URL=//p' "$preflight_out" | head -n 1)"
OK_CHAT_POOL_PRECHECK="$(sed -n 's/^OK_CHAT_POOL_PRECHECK=//p' "$preflight_out" | head -n 1)"
CHAT_POOL_PRECHECK_SUMMARY_JSON="$(sed -n 's/^CHAT_POOL_PRECHECK_SUMMARY_JSON=//p' "$preflight_out" | head -n 1)"
if [[ -z "$LIVE_CHAT_URL" || "$LIVE_CHAT_URL" == "none" ]]; then
  echo "DEMO_STATUS=PRECHECK_FAIL"
  echo "DEMO_PRECHECK_EXIT=14"
  exit 14
fi
export LIVE_CHAT_URL
export LIVE_INIT_SPECIALIST_CHAT="${LIVE_INIT_SPECIALIST_CHAT:-0}"
echo "LIVE_CHAT_URL=$LIVE_CHAT_URL"
echo "LIVE_INIT_SPECIALIST_CHAT=$LIVE_INIT_SPECIALIST_CHAT"

if [[ -n "$LIVE_CHAT_POOL_FILE" ]]; then
  echo "== LIVE POOL =="
  export POOL_FOLLOW_MODE="${POOL_FOLLOW_MODE:-cli}"
  export POOL_FOLLOW_NO_ANSI="${POOL_FOLLOW_NO_ANSI:-1}"
  export POOL_FOLLOW_TICK_MS="${POOL_FOLLOW_TICK_MS:-500}"
  if [[ ! "$LIVE_CONCURRENCY" =~ ^[0-9]+$ ]] || (( LIVE_CONCURRENCY < 1 )); then
    echo "DEMO_STATUS=POOL_FAIL"
    echo "DEMO_POOL_REASON=invalid_live_concurrency"
    exit 2
  fi
  if (( LIVE_CONCURRENCY >= 5 )) && [[ "${OK_CHAT_POOL_PRECHECK:-0}" != "1" ]]; then
    echo "DEMO_STATUS=PRECHECK_FAIL"
    echo "DEMO_PRECHECK_EXIT=16"
    echo "DEMO_PRECHECK_REASON=chat_pool_precheck_not_ok"
    if [[ -n "$CHAT_POOL_PRECHECK_SUMMARY_JSON" && "$CHAT_POOL_PRECHECK_SUMMARY_JSON" != "none" ]]; then
      echo "DEMO_CHAT_POOL_PRECHECK_SUMMARY=$CHAT_POOL_PRECHECK_SUMMARY_JSON"
    fi
    exit 16
  fi
  if [[ ! "$LIVE_ITERATIONS" =~ ^[0-9]+$ ]] || (( LIVE_ITERATIONS < 1 )); then
    echo "DEMO_STATUS=POOL_FAIL"
    echo "DEMO_POOL_REASON=invalid_live_iterations"
    exit 2
  fi
  if [[ ! -f "$LIVE_DEMO_TASKS_FILE" ]]; then
    echo "DEMO_STATUS=POOL_FAIL"
    echo "DEMO_POOL_REASON=demo_tasks_missing"
    echo "DEMO_TASKS_FILE=$LIVE_DEMO_TASKS_FILE"
    exit 3
  fi

  mapfile -t demo_tasks < <(sed -e 's/\r$//' "$LIVE_DEMO_TASKS_FILE" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
  if (( ${#demo_tasks[@]} < LIVE_CONCURRENCY )); then
    echo "DEMO_STATUS=POOL_FAIL"
    echo "DEMO_POOL_REASON=not_enough_demo_tasks"
    echo "DEMO_TASKS_COUNT=${#demo_tasks[@]}"
    echo "DEMO_REQUIRED_TASKS=$LIVE_CONCURRENCY"
    exit 3
  fi

  pool_tasks_file="$tmp_dir/pool_tasks.txt"
  : >"$pool_tasks_file"
  for ((i=0; i<LIVE_CONCURRENCY; i++)); do
    printf '%s\n' "${demo_tasks[$i]}" >>"$pool_tasks_file"
  done

  pool_out="$tmp_dir/pool.out"
  set +e
  RUN_LIVE_CDP_E2E=1 \
  bash "$ROOT_DIR/scripts/agent_pool_run.sh" \
    --project-path "$LIVE_PROJECT_PATH" \
    --tasks-file "$pool_tasks_file" \
    --mode live \
    --concurrency "$LIVE_CONCURRENCY" \
    --iterations "$LIVE_ITERATIONS" \
    --chat-pool-file "$LIVE_CHAT_POOL_FILE" \
    --browser-policy required \
    --open-browser \
    --init-specialist-chat \
    --skip-git-repo-check 2>&1 | tee "$pool_out"
  pool_rc="${PIPESTATUS[0]}"
  set -e
  demo_pool_report_md="$(sed -n 's/^POOL_REPORT_MD=//p' "$pool_out" | tail -n 1)"
  demo_pool_report_json="$(sed -n 's/^POOL_REPORT_JSON=//p' "$pool_out" | tail -n 1)"
  if [[ "$pool_rc" != "0" ]]; then
    echo "DEMO_STATUS=POOL_FAIL"
    echo "DEMO_POOL_EXIT=$pool_rc"
    if [[ -n "$demo_pool_report_md" ]]; then
      echo "DEMO_POOL_REPORT_MD=$demo_pool_report_md"
    fi
    if [[ -n "$demo_pool_report_json" ]]; then
      echo "DEMO_POOL_REPORT_JSON=$demo_pool_report_json"
    fi
    exit "$pool_rc"
  fi

  if [[ -n "$demo_pool_report_md" ]]; then
    echo "DEMO_POOL_REPORT_MD=$demo_pool_report_md"
  fi
  if [[ -n "$demo_pool_report_json" ]]; then
    echo "DEMO_POOL_REPORT_JSON=$demo_pool_report_json"
  fi
  if [[ -n "$CHAT_POOL_PRECHECK_SUMMARY_JSON" && "$CHAT_POOL_PRECHECK_SUMMARY_JSON" != "none" ]]; then
    echo "DEMO_CHAT_POOL_PRECHECK_SUMMARY=$CHAT_POOL_PRECHECK_SUMMARY_JSON"
  fi
  echo "DEMO_STATUS=OK"
  exit 0
fi

echo "== LIVE BOOTSTRAP ONCE =="
bootstrap_out="$tmp_dir/bootstrap.out"
set +e
bash "$ROOT_DIR/scripts/live_specialist_bootstrap_once.sh" >"$bootstrap_out" 2>&1
bootstrap_rc=$?
set -e
cat "$bootstrap_out"
if [[ "$bootstrap_rc" != "0" ]]; then
  echo "DEMO_STATUS=BOOTSTRAP_FAIL"
  echo "DEMO_BOOTSTRAP_EXIT=$bootstrap_rc"
  exit "$bootstrap_rc"
fi

echo "== LIVE SMOKE =="
smoke_out="$tmp_dir/smoke.out"
set +e
LIVE_ARTIFACT_DIR="$tmp_dir/smoke_artifacts" bash "$ROOT_DIR/test/test_spawn_second_agent_e2e_cdp_smoke.sh" >"$smoke_out" 2>&1
smoke_rc=$?
set -e
cat "$smoke_out"
if [[ "$smoke_rc" != "0" ]]; then
  echo "DEMO_STATUS=SMOKE_FAIL"
  echo "DEMO_SMOKE_EXIT=$smoke_rc"
  exit "$smoke_rc"
fi
if rg -q '^SKIP_' "$smoke_out"; then
  echo "DEMO_STATUS=SMOKE_SKIP"
  exit 0
fi

smoke_result_json="$(sed -n 's/^CHILD_RESULT_JSON=//p' "$smoke_out" | head -n 1)"
smoke_transport_log="$(sed -n 's/^TRANSPORT_LOG=//p' "$smoke_out" | head -n 1)"
print_json_summary "SMOKE" "$smoke_result_json"
echo "SMOKE_TRANSPORT_LOG=$smoke_transport_log"
if [[ -f "$smoke_transport_log" ]]; then
  echo "-- SMOKE transport tail (30) --"
  tail -n 30 "$smoke_transport_log"
fi

echo "== LIVE PARALLEL =="
parallel_out="$tmp_dir/parallel.out"
set +e
LIVE_ARTIFACT_DIR="$tmp_dir/parallel_artifacts" bash "$ROOT_DIR/test/test_multi_agent_parallel_e2e_cdp_shared_slots.sh" >"$parallel_out" 2>&1
parallel_rc=$?
set -e
cat "$parallel_out"
if [[ "$parallel_rc" != "0" ]]; then
  echo "DEMO_STATUS=PARALLEL_FAIL"
  echo "DEMO_PARALLEL_EXIT=$parallel_rc"
  exit "$parallel_rc"
fi
if rg -q '^SKIP_' "$parallel_out"; then
  echo "DEMO_STATUS=PARALLEL_SKIP"
  exit 0
fi

par_result_json_a="$(sed -n 's/^CHILD_RESULT_JSON_A=//p' "$parallel_out" | head -n 1)"
par_result_json_b="$(sed -n 's/^CHILD_RESULT_JSON_B=//p' "$parallel_out" | head -n 1)"
par_transport_a="$(sed -n 's/^TRANSPORT_LOG_A=//p' "$parallel_out" | head -n 1)"
par_transport_b="$(sed -n 's/^TRANSPORT_LOG_B=//p' "$parallel_out" | head -n 1)"
print_json_summary "PARALLEL_A" "$par_result_json_a"
print_json_summary "PARALLEL_B" "$par_result_json_b"
echo "PARALLEL_TRANSPORT_LOG_A=$par_transport_a"
echo "PARALLEL_TRANSPORT_LOG_B=$par_transport_b"
if [[ -f "$par_transport_a" ]]; then
  echo "-- PARALLEL A transport tail (30) --"
  tail -n 30 "$par_transport_a"
fi
if [[ -f "$par_transport_b" ]]; then
  echo "-- PARALLEL B transport tail (30) --"
  tail -n 30 "$par_transport_b"
fi

echo "DEMO_STATUS=OK"
