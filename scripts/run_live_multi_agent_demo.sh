#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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
if [[ -z "$LIVE_CHAT_URL" || "$LIVE_CHAT_URL" == "none" ]]; then
  echo "DEMO_STATUS=PRECHECK_FAIL"
  echo "DEMO_PRECHECK_EXIT=14"
  exit 14
fi
export LIVE_CHAT_URL
export LIVE_INIT_SPECIALIST_CHAT="${LIVE_INIT_SPECIALIST_CHAT:-0}"
echo "LIVE_CHAT_URL=$LIVE_CHAT_URL"
echo "LIVE_INIT_SPECIALIST_CHAT=$LIVE_INIT_SPECIALIST_CHAT"

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
