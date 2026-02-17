#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="prod"
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    *)
      if [[ -z "${RUN_ID:-}" ]]; then
        RUN_ID="$1"
        shift
      else
        echo "Unknown arg: $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "${RUN_ID//[[:space:]]/}" ]]; then
  echo "Usage: $0 [--profile prod|soak] --run-id <RUN_ID>" >&2
  exit 2
fi
if [[ "$PROFILE" != "prod" && "$PROFILE" != "soak" ]]; then
  echo "Unsupported profile: $PROFILE (expected: prod|soak)" >&2
  exit 2
fi

RUN_DIR="$ROOT/state/runs/$RUN_ID"
THRESHOLDS_FILE="$ROOT/docs/RELEASE_GATE.md"

if [[ ! -d "$RUN_DIR" ]]; then
  echo "RUN_DIR not found: $RUN_DIR" >&2
  exit 2
fi
if [[ ! -f "$THRESHOLDS_FILE" ]]; then
  echo "Thresholds file not found: $THRESHOLDS_FILE" >&2
  exit 2
fi

mapfile -t LOG_FILES < <(find "$RUN_DIR" -type f ! -name 'gate_check.log' 2>/dev/null | sort)
if [[ -d "/tmp/chatgpt-send-child" ]]; then
  while IFS= read -r f; do
    LOG_FILES+=("$f")
  done < <(find /tmp/chatgpt-send-child -type f -name "*${RUN_ID}*" 2>/dev/null | sort)
fi

if [[ "${#LOG_FILES[@]}" -eq 0 ]]; then
  echo "No log files found for run_id=$RUN_ID" >&2
  exit 2
fi

python3 - "$RUN_ID" "$PROFILE" "$THRESHOLDS_FILE" "${LOG_FILES[@]}" <<'PY'
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

run_id = sys.argv[1]
profile = sys.argv[2].strip().lower()
thresholds_path = Path(sys.argv[3])
files = [Path(p) for p in sys.argv[4:]]

def parse_thresholds(text: str, profile_name: str):
    lines = text.splitlines()
    target = f"THRESHOLDS_{profile_name.upper()}"
    in_target = False
    in_code = False
    out = {}
    for raw in lines:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not in_target:
            if target in stripped:
                in_target = True
            continue
        if not in_code:
            if stripped.startswith("```"):
                in_code = True
            continue
        if stripped.startswith("```"):
            break
        m = re.match(r"^([A-Z0-9_]+)=([0-9]+(?:\.[0-9]+)?)$", stripped)
        if m:
            out[m.group(1)] = float(m.group(2))
    if out:
        return out
    # Backward compatibility fallback: parse flat KEY=VALUE lines from whole doc.
    for raw in lines:
        stripped = raw.strip()
        m = re.match(r"^([A-Z0-9_]+)=([0-9]+(?:\.[0-9]+)?)$", stripped)
        if m:
            out[m.group(1)] = float(m.group(2))
    return out

thresholds = parse_thresholds(thresholds_path.read_text(encoding="utf-8", errors="ignore"), profile)

if not thresholds:
    print(f"No machine thresholds found in {thresholds_path}", file=sys.stderr)
    sys.exit(2)

counts = defaultdict(int)
evidence = {}
lock_wait = []
lock_held = []
slot_events = []
precheck_ms_values = []
send_ms_values = []
wait_reply_ms_values = []
total_ms_values = []
soak_iters = 0
soak_fails = 0
iter_status_per_child = defaultdict(int)
expected_negative_errors_total = 0
tests_skipped = 0
doctor_invariants_ok = 0
doctor_force_set = 0
doctor_profile_used = 0

def set_evidence(key: str, path: Path, line_no: int) -> None:
    if key not in evidence:
        evidence[key] = f"{path}:{line_no}"

marker_keys = {
    "E_ROUTE_MISMATCH": "E_ROUTE_MISMATCH",
    "E_ROUTE_MISMATCH_FATAL": "E_ROUTE_MISMATCH_FATAL",
    "E_SLOT_ACQUIRE_TIMEOUT": "E_SLOT_ACQUIRE_TIMEOUT",
    "E_CDP_RECOVER_BUDGET_EXCEEDED": "E_CDP_RECOVER_BUDGET_EXCEEDED",
    "E_SEND_WITHOUT_PRECHECK": "E_SEND_WITHOUT_PRECHECK",
    "E_TARGET_CHAT_REQUIRED": "E_TARGET_CHAT_REQUIRED",
    "E_CHAT_STATE_MISMATCH": "E_CHAT_STATE_MISMATCH",
    "E_FLOW_ORDER_VIOLATION": "E_FLOW_ORDER_VIOLATION",
    "E_MESSAGE_NOT_ECHOED": "E_MESSAGE_NOT_ECHOED",
    "E_AUTO_WAIT_TIMEOUT": "E_AUTO_WAIT_TIMEOUT",
    "E_REPLY_WAIT_TIMEOUT": "E_REPLY_WAIT_TIMEOUT",
    "E_PROD_CHAT_PROTECTED": "E_PROD_CHAT_PROTECTED",
    "E_SOFT_RESET_FAILED": "E_SOFT_RESET_FAILED",
    "COMPOSER_TIMEOUT": "COMPOSER_TIMEOUT",
    "RUNTIME_EVAL_TIMEOUT": "RUNTIME_EVAL_TIMEOUT",
    "E_CDP_PORT_IN_USE": "E_CDP_PORT_IN_USE",
    "SLOT_RELEASE_FORCED": "SLOT_RELEASE_FORCED",
}

recover_re = re.compile(r"E_CDP_UNREACHABLE\.recover_")
auto_wait_start_re = re.compile(r"\bAUTO_WAIT start\b")
soft_reset_start_re = re.compile(r"\bSOFT_RESET start\b")
soft_reset_success_re = re.compile(r"\bSOFT_RESET done outcome=success\b")
slot_re = re.compile(r"SLOT_(ACQUIRE|RELEASE).*?ts_ms=([0-9]+)")
lock_wait_re = re.compile(r"\[LOCK\].*wait_ms=([0-9]+)")
lock_held_re = re.compile(r"\[LOCK\].*lock_held_ms=([0-9]+)")
iter_re = re.compile(r"ITER_STATUS .*child_id=([^ ]+)")
skip_re = re.compile(r"tests_skipped=([0-9]+)")
precheck_ms_re = re.compile(r"\bprecheck_ms=([0-9]+(?:\.[0-9]+)?)")
send_ms_re = re.compile(r"\bsend_ms=([0-9]+(?:\.[0-9]+)?)")
wait_reply_ms_re = re.compile(r"\bwait_reply_ms=([0-9]+(?:\.[0-9]+)?)")
total_ms_re = re.compile(r"\btotal_ms=([0-9]+(?:\.[0-9]+)?)")
soak_done_re = re.compile(r"SOAK_ITER done .*?rc=([0-9]+)")
profile_dir_re = re.compile(r"\bPROFILE_DIR path=")
profile_wrap_re = re.compile(r"\bPROFILE_WRAP run_id=")
cleanup_killed_re = re.compile(r"\bCLEANUP_KILLED_TOTAL=([0-9]+)")
doctor_inv_re = re.compile(r'"invariants_ok"\s*:\s*([01]|true|false)', re.IGNORECASE)
doctor_force_re = re.compile(r'"force_chat_url_set"\s*:\s*([01]|true|false)', re.IGNORECASE)
doctor_profile_re = re.compile(r'"profile_dir_used"\s*:\s*([01]|true|false)', re.IGNORECASE)

for path in files:
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        continue
    is_negative_file = any(("NEGATIVE_EXPECTED" in ln) or ("EXPECT_ERROR=" in ln) for ln in lines)
    for i, line in enumerate(lines, start=1):
        if line.startswith("RELEASE_GATE:") or line.startswith("METRIC ") or line.startswith("FAIL key="):
            continue
        if is_negative_file and "E_" in line:
            expected_negative_errors_total += 1
        for key, token in marker_keys.items():
            if is_negative_file:
                continue
            if token in line:
                counts[key] += 1
                set_evidence(key, path, i)
        if not is_negative_file and auto_wait_start_re.search(line):
            counts["AUTO_WAIT_TOTAL"] += 1
            set_evidence("AUTO_WAIT_TOTAL", path, i)
        if not is_negative_file and soft_reset_start_re.search(line):
            counts["SOFT_RESET_TOTAL"] += 1
            set_evidence("SOFT_RESET_TOTAL", path, i)
        if not is_negative_file and soft_reset_success_re.search(line):
            counts["SOFT_RESET_SUCCESS_TOTAL"] += 1
            set_evidence("SOFT_RESET_SUCCESS_TOTAL", path, i)
        if is_negative_file:
            continue
        if recover_re.search(line):
            counts["E_CDP_UNREACHABLE_RECOVER"] += 1
            set_evidence("E_CDP_UNREACHABLE_RECOVER_PER_100", path, i)
        m = slot_re.search(line)
        if m:
            slot_events.append((int(m.group(2)), m.group(1)))
            set_evidence("MAX_INFLIGHT_SLOTS", path, i)
        m = lock_wait_re.search(line)
        if m:
            lock_wait.append(int(m.group(1)))
            set_evidence("P95_LOCK_WAIT_MS", path, i)
        m = lock_held_re.search(line)
        if m:
            lock_held.append(int(m.group(1)))
            set_evidence("P95_LOCK_HELD_MS", path, i)
        m = iter_re.search(line)
        if m:
            child = m.group(1)
            iter_status_per_child[child] += 1
            set_evidence("MIN_ITER_STATUS_LINES_PER_CHILD", path, i)
        m = skip_re.search(line)
        if m:
            tests_skipped = max(tests_skipped, int(m.group(1)))
            set_evidence("MAX_TESTS_SKIPPED", path, i)
        m = precheck_ms_re.search(line)
        if m:
            precheck_ms_values.append(float(m.group(1)))
            set_evidence("P95_PRECHECK_MS", path, i)
        m = send_ms_re.search(line)
        if m:
            send_ms_values.append(float(m.group(1)))
            set_evidence("P95_SEND_MS", path, i)
        m = wait_reply_ms_re.search(line)
        if m:
            wait_reply_ms_values.append(float(m.group(1)))
            set_evidence("P95_WAIT_REPLY_MS", path, i)
        m = total_ms_re.search(line)
        if m:
            total_ms_values.append(float(m.group(1)))
            set_evidence("P95_TOTAL_MS", path, i)
        m = soak_done_re.search(line)
        if m:
            soak_iters += 1
            rc = int(m.group(1))
            if rc != 0:
                soak_fails += 1
                set_evidence("SOAK_FAILS", path, i)
            set_evidence("SOAK_ITERS", path, i)
        if profile_dir_re.search(line):
            counts["PROFILE_DIR_USED_TOTAL"] += 1
            set_evidence("PROFILE_DIR_USED_TOTAL", path, i)
        if profile_wrap_re.search(line):
            counts["PROFILE_DIR_USED_TOTAL"] += 1
            set_evidence("PROFILE_DIR_USED_TOTAL", path, i)
        m = cleanup_killed_re.search(line)
        if m:
            counts["CLEANUP_KILLED_TOTAL"] += int(float(m.group(1)))
            set_evidence("CLEANUP_KILLED_TOTAL", path, i)
        m = doctor_inv_re.search(line)
        if m:
            v = m.group(1).lower()
            doctor_invariants_ok = max(doctor_invariants_ok, 1 if v in ("1", "true") else 0)
            set_evidence("DOCTOR_INVARIANTS_OK", path, i)
        m = doctor_force_re.search(line)
        if m:
            v = m.group(1).lower()
            doctor_force_set = max(doctor_force_set, 1 if v in ("1", "true") else 0)
            set_evidence("DOCTOR_FORCE_CHAT_URL_SET", path, i)
        m = doctor_profile_re.search(line)
        if m:
            v = m.group(1).lower()
            doctor_profile_used = max(doctor_profile_used, 1 if v in ("1", "true") else 0)
            set_evidence("DOCTOR_PROFILE_DIR_USED", path, i)

def p95(values):
    if not values:
        return 0.0
    arr = sorted(values)
    rank = int(math.ceil(0.95 * len(arr))) - 1
    rank = max(0, min(rank, len(arr) - 1))
    return float(arr[rank])

slot_events.sort(key=lambda x: (x[0], 0 if x[1] == "RELEASE" else 1))
inflight = 0
max_inflight = 0
for _, kind in slot_events:
    if kind == "ACQUIRE":
        inflight += 1
        max_inflight = max(max_inflight, inflight)
    else:
        inflight = max(0, inflight - 1)

min_iter_status = min(iter_status_per_child.values()) if iter_status_per_child else 0

metrics = {
    "E_ROUTE_MISMATCH": float(counts["E_ROUTE_MISMATCH"]),
    "E_ROUTE_MISMATCH_FATAL": float(counts["E_ROUTE_MISMATCH_FATAL"]),
    "E_SLOT_ACQUIRE_TIMEOUT": float(counts["E_SLOT_ACQUIRE_TIMEOUT"]),
    "E_CDP_RECOVER_BUDGET_EXCEEDED": float(counts["E_CDP_RECOVER_BUDGET_EXCEEDED"]),
    "E_SEND_WITHOUT_PRECHECK": float(counts["E_SEND_WITHOUT_PRECHECK"]),
    "E_TARGET_CHAT_REQUIRED": float(counts["E_TARGET_CHAT_REQUIRED"]),
    "E_CHAT_STATE_MISMATCH": float(counts["E_CHAT_STATE_MISMATCH"]),
    "E_FLOW_ORDER_VIOLATION": float(counts["E_FLOW_ORDER_VIOLATION"]),
    "E_MESSAGE_NOT_ECHOED": float(counts["E_MESSAGE_NOT_ECHOED"]),
    "AUTO_WAIT_TOTAL": float(counts["AUTO_WAIT_TOTAL"]),
    "AUTO_WAIT_TIMEOUT_TOTAL": float(counts["E_AUTO_WAIT_TIMEOUT"]),
    "E_REPLY_WAIT_TIMEOUT": float(counts["E_REPLY_WAIT_TIMEOUT"]),
    "E_PROD_CHAT_PROTECTED": float(counts["E_PROD_CHAT_PROTECTED"]),
    "SOFT_RESET_TOTAL": float(counts["SOFT_RESET_TOTAL"]),
    "SOFT_RESET_SUCCESS_TOTAL": float(counts["SOFT_RESET_SUCCESS_TOTAL"]),
    "E_SOFT_RESET_FAILED_TOTAL": float(counts["E_SOFT_RESET_FAILED"]),
    "COMPOSER_TIMEOUT_TOTAL": float(counts["COMPOSER_TIMEOUT"]),
    "RUNTIME_EVAL_TIMEOUT_TOTAL": float(counts["RUNTIME_EVAL_TIMEOUT"]),
    "E_CDP_PORT_IN_USE": float(counts["E_CDP_PORT_IN_USE"]),
    "SLOT_RELEASE_FORCED_TOTAL": float(counts["SLOT_RELEASE_FORCED"]),
    "CLEANUP_KILLED_TOTAL": float(counts["CLEANUP_KILLED_TOTAL"]),
    "DOCTOR_INVARIANTS_OK": float(doctor_invariants_ok),
    "DOCTOR_FORCE_CHAT_URL_SET": float(doctor_force_set),
    "DOCTOR_PROFILE_DIR_USED": float(doctor_profile_used),
    "E_CDP_UNREACHABLE_RECOVER_PER_100": float(counts["E_CDP_UNREACHABLE_RECOVER"]),
    "E_CDP_UNREACHABLE_PER_200": float(counts["E_CDP_UNREACHABLE_RECOVER"]),
    "MAX_INFLIGHT_SLOTS": float(max_inflight),
    "P95_LOCK_WAIT_MS": p95(lock_wait),
    "P95_LOCK_HELD_MS": p95(lock_held),
    "P95_PRECHECK_MS": p95(precheck_ms_values),
    "P95_SEND_MS": p95(send_ms_values),
    "P95_WAIT_REPLY_MS": p95(wait_reply_ms_values),
    "P95_TOTAL_MS": p95(total_ms_values),
    "SOAK_ITERS": float(soak_iters),
    "SOAK_FAILS": float(soak_fails),
    "PROFILE_DIR_USED_TOTAL": float(counts["PROFILE_DIR_USED_TOTAL"]),
    "MIN_ITER_STATUS_LINES_PER_CHILD": float(min_iter_status),
    "EXPECTED_NEGATIVE_ERRORS_TOTAL": float(expected_negative_errors_total),
    "TESTS_SKIPPED": float(tests_skipped),
}
metrics["CHAT_MISROUTE_TOTAL"] = (
    metrics["E_ROUTE_MISMATCH_FATAL"]
    + metrics["E_TARGET_CHAT_REQUIRED"]
    + metrics["E_CHAT_STATE_MISMATCH"]
)

print(f"RELEASE_GATE: run_id={run_id} profile={profile}")
for key in sorted(metrics.keys()):
    val = metrics[key]
    if abs(val - int(val)) < 1e-9:
        val_out = str(int(val))
    else:
        val_out = f"{val:.3f}"
    print(f"METRIC {key}={val_out}")

fails = []
for key, limit in sorted(thresholds.items()):
    metric_key = key
    mode = "eq"
    if key.startswith("MAX_"):
        metric_key = key[4:]
        mode = "max"
    elif key.startswith("MIN_"):
        metric_key = key[4:]
        mode = "min"
    actual = metrics.get(metric_key)
    if actual is None:
        continue
    bad = False
    if mode == "max":
        bad = actual > limit
    elif mode == "min":
        bad = actual < limit
    if bad:
        ev = evidence.get(metric_key) or evidence.get(key) or "n/a"
        fails.append((key, actual, limit, ev))

if fails:
    print(f"RELEASE_GATE: FAIL run_id={run_id} profile={profile}")
    for key, actual, limit, ev in fails:
        a = int(actual) if abs(actual - int(actual)) < 1e-9 else round(actual, 3)
        l = int(limit) if abs(limit - int(limit)) < 1e-9 else round(limit, 3)
        print(f"FAIL key={key} actual={a} limit={l} evidence={ev}")
    sys.exit(1)

print(f"RELEASE_GATE: PASS run_id={run_id} profile={profile}")
PY
