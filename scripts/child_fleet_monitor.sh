#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/child_fleet_monitor.sh --pool-run-dir DIR [options]

Required:
  --pool-run-dir DIR   Pool run root (expects logs/<agent>/<run_id>/...)

Options:
  --poll-sec N         (default: 2)
  --heartbeat-sec N    (default: 20, 0 disables heartbeat)
  --timeout-sec N      (default: 0, disabled)
  --stuck-after-sec N  (default: 240)
  --pid-file FILE      (default: <pool-run-dir>/fleet.monitor.pid)
  --monitor-log FILE   (default: <pool-run-dir>/fleet.monitor.log)
  --summary-json FILE  (default: <pool-run-dir>/fleet.summary.json)
  --summary-csv FILE   (default: <pool-run-dir>/fleet.summary.csv)
  --registry-file FILE (default: <pool-run-dir>/fleet_registry.jsonl)
  --roster-jsonl FILE  (default: <pool-run-dir>/fleet_roster.jsonl)
  --lock-file FILE     (default: <pool-run-dir>/fleet.monitor.lock)
  Env passthrough:
    CODEX_SWARM_STATUS_FILE      If set, also writes a Codex TUI swarm status JSON (swarm-status.v1)
    CODEX_SWARM_STATUS_POLL_MS   Read by patched Codex TUI (not used by this script)
  --stdout             (mirror monitor events to stdout)
  -h, --help
USAGE
}

POOL_RUN_DIR=""
POLL_SEC=2
HEARTBEAT_SEC=20
TIMEOUT_SEC=0
STUCK_AFTER_SEC=240
MONITOR_LOG=""
SUMMARY_JSON=""
SUMMARY_CSV=""
REGISTRY_FILE=""
ROSTER_JSONL=""
LOCK_FILE=""
OUT_PID_FILE=""
TO_STDOUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-run-dir) POOL_RUN_DIR="${2:-}"; shift 2 ;;
    --poll-sec) POLL_SEC="${2:-}"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="${2:-}"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --stuck-after-sec) STUCK_AFTER_SEC="${2:-}"; shift 2 ;;
    --pid-file) OUT_PID_FILE="${2:-}"; shift 2 ;;
    --monitor-log) MONITOR_LOG="${2:-}"; shift 2 ;;
    --summary-json) SUMMARY_JSON="${2:-}"; shift 2 ;;
    --summary-csv) SUMMARY_CSV="${2:-}"; shift 2 ;;
    --registry-file) REGISTRY_FILE="${2:-}"; shift 2 ;;
    --roster-jsonl) ROSTER_JSONL="${2:-}"; shift 2 ;;
    --lock-file) LOCK_FILE="${2:-}"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$POOL_RUN_DIR" ]]; then
  usage >&2
  exit 2
fi
for n in "$POLL_SEC" "$HEARTBEAT_SEC" "$TIMEOUT_SEC" "$STUCK_AFTER_SEC"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "numeric option expected, got: $n" >&2
    exit 2
  fi
done
if (( POLL_SEC < 1 )); then
  echo "--poll-sec must be >= 1" >&2
  exit 2
fi
if (( HEARTBEAT_SEC < 0 || TIMEOUT_SEC < 0 )); then
  echo "--heartbeat-sec and --timeout-sec must be >= 0" >&2
  exit 2
fi
if (( STUCK_AFTER_SEC < 1 )); then
  echo "--stuck-after-sec must be >= 1" >&2
  exit 2
fi
if [[ ! -d "$POOL_RUN_DIR" ]]; then
  echo "pool run dir not found: $POOL_RUN_DIR" >&2
  exit 2
fi
if [[ -z "$MONITOR_LOG" ]]; then
  MONITOR_LOG="$POOL_RUN_DIR/fleet.monitor.log"
fi
if [[ -z "$SUMMARY_JSON" ]]; then
  SUMMARY_JSON="$POOL_RUN_DIR/fleet.summary.json"
fi
if [[ -z "$SUMMARY_CSV" ]]; then
  SUMMARY_CSV="$POOL_RUN_DIR/fleet.summary.csv"
fi
if [[ -z "$REGISTRY_FILE" ]]; then
  REGISTRY_FILE="$POOL_RUN_DIR/fleet_registry.jsonl"
fi
if [[ -z "$ROSTER_JSONL" ]]; then
  ROSTER_JSONL="$POOL_RUN_DIR/fleet_roster.jsonl"
fi
if [[ -z "$LOCK_FILE" ]]; then
  LOCK_FILE="$POOL_RUN_DIR/fleet.monitor.lock"
fi
if [[ -z "$OUT_PID_FILE" ]]; then
  OUT_PID_FILE="$POOL_RUN_DIR/fleet.monitor.pid"
fi
HEARTBEAT_FILE="${FLEET_HEARTBEAT_FILE:-$POOL_RUN_DIR/fleet.heartbeat}"
EVENTS_JSONL="${FLEET_EVENTS_JSONL:-$POOL_RUN_DIR/fleet.events.jsonl}"
EVENTS_LOCK_FILE="${FLEET_EVENTS_LOCK_FILE:-$POOL_RUN_DIR/fleet.events.lock}"
FLEET_DISK_PATH="${FLEET_DISK_PATH:-$POOL_RUN_DIR}"
FLEET_DISK_FREE_WARN_PCT="${FLEET_DISK_FREE_WARN_PCT:-10}"
FLEET_DISK_FREE_FAIL_PCT="${FLEET_DISK_FREE_FAIL_PCT:-5}"
CODEX_SWARM_STATUS_JSON="${FLEET_CODEX_SWARM_STATUS_JSON:-${CODEX_SWARM_STATUS_FILE:-}}"

now_iso() { date -Iseconds; }
now_epoch() { date +%s; }
now_ms() {
  date +%s%3N 2>/dev/null || python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

short_line() {
  local line="${1:-}"
  line="$(printf '%s' "$line" | tr '\r' ' ' | tr '\n' ' ')"
  line="$(printf '%s' "$line" | tr '\t' ' ' | sed 's/[[:space:]]\+/ /g')"
  printf '%s' "$line" | cut -c1-360
}

normalize_chat_url() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$raw" ]] || return 0
  if [[ "$raw" =~ ^https://chatgpt\.com/c/([A-Za-z0-9-]+)([/?#].*)?$ ]]; then
    printf 'https://chatgpt.com/c/%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^https://chatgpt\.com/?([?#].*)?$ ]]; then
    return 0
  fi
  return 0
}

extract_evidence_chat_url() {
  local log_file="${1:-}"
  [[ -f "$log_file" ]] || return 0
  tail -n 200 "$log_file" 2>/dev/null \
    | sed -n 's/.*EVIDENCE:[[:space:]]*\(https:\/\/chatgpt\.com[^[:space:]]*\).*/\1/p' \
    | tail -n 1
}

log_event() {
  local msg="$1"
  local line="[fleet-monitor] ts=$(now_iso) pool_run_dir=${POOL_RUN_DIR} ${msg}"
  printf '%s\n' "$line" >>"$MONITOR_LOG"
  if [[ "$TO_STDOUT" == "1" ]]; then
    printf '%s\n' "$line"
  fi
}

file_mtime() {
  local file="$1"
  if [[ -f "$file" ]]; then
    stat -c '%Y' "$file" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

read_pid() {
  local file="$1"
  if [[ -f "$file" ]]; then
    tr -d '[:space:]' <"$file" 2>/dev/null || true
  fi
}

is_alive_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

mkdir -p "$(dirname "$MONITOR_LOG")"
mkdir -p "$(dirname "$SUMMARY_JSON")"
mkdir -p "$(dirname "$SUMMARY_CSV")"
if [[ -n "${CODEX_SWARM_STATUS_JSON:-}" ]]; then
  mkdir -p "$(dirname "$CODEX_SWARM_STATUS_JSON")"
fi
mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$(dirname "$OUT_PID_FILE")"
mkdir -p "$(dirname "$HEARTBEAT_FILE")"
mkdir -p "$(dirname "$EVENTS_JSONL")"
mkdir -p "$(dirname "$EVENTS_LOCK_FILE")"
mkdir -p "$(dirname "$ROSTER_JSONL")"

for n in "$FLEET_DISK_FREE_WARN_PCT" "$FLEET_DISK_FREE_FAIL_PCT"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "disk threshold must be numeric, got: $n" >&2
    exit 2
  fi
done
if (( FLEET_DISK_FREE_WARN_PCT > 100 || FLEET_DISK_FREE_FAIL_PCT > 100 )); then
  echo "disk thresholds must be <= 100" >&2
  exit 2
fi
if (( FLEET_DISK_FREE_FAIL_PCT > FLEET_DISK_FREE_WARN_PCT )); then
  echo "FLEET_DISK_FREE_FAIL_PCT must be <= FLEET_DISK_FREE_WARN_PCT" >&2
  exit 2
fi

lock_fd=""
exec {lock_fd}>"$LOCK_FILE"
if ! flock -n "$lock_fd"; then
  log_event "event=lock_busy lock_file=${LOCK_FILE}"
  exit 73
fi
printf '%s\n' "$$" >"$OUT_PID_FILE"

cleanup() {
  local rc=$?
  rm -f "$OUT_PID_FILE" >/dev/null 2>&1 || true
  if [[ -n "${lock_fd:-}" ]]; then
    exec {lock_fd}>&- || true
  fi
  if (( rc != 0 )); then
    log_event "event=exit rc=${rc}"
  fi
}
trap cleanup EXIT INT TERM

declare -a ORDERED_KEYS=()
declare -A KEY_SEEN=()
declare -A AGENT_ID RUN_ID RUN_DIR ASSIGNED_CHAT_URL
declare -A PID_FILE EXIT_FILE LAST_FILE RESULT_JSON STATUS_FILE LOG_FILE
declare -A STATE_CLASS STATE_REASON LEGACY_STATE
declare -A PID_VALUE ALIVE EXIT_CODE RESULT_STATUS RESULT_EXIT RESULT_PARSE_ERR
declare -A LAST_STEP LAST_TAIL AGE_SEC LAST_UPDATE_EPOCH
declare -A OBSERVED_CHAT_URL_BEFORE OBSERVED_CHAT_URL_AFTER
declare -A ASSIGNED_CHAT_URL_NORM OBSERVED_CHAT_URL_NORM CHAT_PROOF
declare -A RESULT_MTIME_CACHE
declare -A PREV_CLASS
declare -A PREV_ASSIGNED_CHAT_URL_NORM PREV_OBSERVED_CHAT_URL_NORM PREV_CHAT_PROOF

registry_bad_lines_prev="-1"
roster_bad_lines_prev="-1"
DISK_STATUS="unknown"
DISK_FREE_PCT=""
DISK_AVAIL_KB=""
disk_status_prev=""
DISCOVERY_REGISTRY_COUNT=0
DISCOVERY_ROSTER_COUNT=0
DISCOVERY_MERGED_COUNT=0
MISSING_ARTIFACTS_TOTAL=0
LAST_DISCOVERED_KEY=""

write_heartbeat() {
  local ts_ms
  ts_ms="$(now_ms)"
  local tmp_file="${HEARTBEAT_FILE}.tmp.$$"
  printf 'ts_ms=%s\n' "$ts_ms" >"$tmp_file"
  mv -f "$tmp_file" "$HEARTBEAT_FILE"
  log_event "FLEET_HEARTBEAT write ts_ms=${ts_ms} file=${HEARTBEAT_FILE}"
}

append_transition_event() {
  local key="$1"
  local prev_class="$2"
  local new_class="$3"
  local reason="$4"
  local step="$5"
  local ts_ms
  ts_ms="$(now_ms)"
  local payload=""
  payload="$(python3 - \
    "$ts_ms" "${AGENT_ID[$key]}" "${RUN_ID[$key]}" "${RUN_DIR[$key]}" \
    "$prev_class" "$new_class" "$reason" "$step" "${ASSIGNED_CHAT_URL[$key]}" \
    "${OBSERVED_CHAT_URL_BEFORE[$key]}" "${OBSERVED_CHAT_URL_AFTER[$key]}" <<'PY'
import json
import sys

(
    ts_ms,
    agent_id,
    run_id,
    run_dir,
    prev_state,
    new_state,
    reason,
    last_step,
    assigned_chat_url,
    observed_before,
    observed_after,
) = sys.argv[1:12]

obj = {
    "ts_ms": int(ts_ms) if ts_ms.isdigit() else ts_ms,
    "agent_id": agent_id,
    "run_id": run_id,
    "run_dir": run_dir,
    "prev_state": prev_state or None,
    "new_state": new_state,
    "reason": reason or None,
    "last_step": last_step or None,
    "assigned_chat_url": assigned_chat_url or None,
    "observed_chat_url_before": observed_before or None,
    "observed_chat_url_after": observed_after or None,
}
print(json.dumps(obj, ensure_ascii=False))
PY
)"
  if [[ -n "$payload" ]]; then
    local ev_fd=""
    exec {ev_fd}>>"$EVENTS_LOCK_FILE" || true
    if [[ -n "$ev_fd" ]]; then
      flock -w 2 "$ev_fd" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$payload" >>"$EVENTS_JSONL"
    if [[ -n "$ev_fd" ]]; then
      exec {ev_fd}>&- || true
    fi
  fi
  log_event "FLEET_EVENT run_id=${RUN_ID[$key]} prev=${prev_class:-none} new=${new_class} reason=$(short_line "$reason")"
}

refresh_disk_status() {
  local df_line=""
  df_line="$(df -Pk "$FLEET_DISK_PATH" 2>/dev/null | awk 'NR==2 {print $4 "|" $5}')"
  if [[ -z "$df_line" ]]; then
    DISK_STATUS="unknown"
    DISK_FREE_PCT=""
    DISK_AVAIL_KB=""
    return 0
  fi

  local avail_kb="${df_line%%|*}"
  local used_pct="${df_line#*|}"
  used_pct="${used_pct%\%}"
  if [[ ! "$avail_kb" =~ ^[0-9]+$ ]] || [[ ! "$used_pct" =~ ^[0-9]+$ ]]; then
    DISK_STATUS="unknown"
    DISK_FREE_PCT=""
    DISK_AVAIL_KB=""
    return 0
  fi

  local free_pct=$((100 - used_pct))
  if (( free_pct < 0 )); then
    free_pct=0
  fi

  DISK_AVAIL_KB="$avail_kb"
  DISK_FREE_PCT="$free_pct"
  if (( free_pct <= FLEET_DISK_FREE_FAIL_PCT )); then
    DISK_STATUS="fail"
  elif (( free_pct <= FLEET_DISK_FREE_WARN_PCT )); then
    DISK_STATUS="warn"
  else
    DISK_STATUS="ok"
  fi

  if [[ "$DISK_STATUS" != "$disk_status_prev" ]]; then
    log_event "event=disk_status status=${DISK_STATUS} free_pct=${DISK_FREE_PCT:-none} avail_kb=${DISK_AVAIL_KB:-none} path=${FLEET_DISK_PATH}"
    disk_status_prev="$DISK_STATUS"
  fi
}

add_child_run() {
  local run_id_in="${1:-}"
  local run_dir_in="${2:-}"
  local agent_in="${3:-}"
  local assigned_chat_in="${4:-}"
  LAST_DISCOVERED_KEY=""
  local run_dir_trim="${run_dir_in%/}"
  if [[ -z "$run_dir_trim" ]]; then
    return 0
  fi
  local run_id_trim="$run_id_in"
  if [[ -z "$run_id_trim" ]]; then
    run_id_trim="$(basename "$run_dir_trim")"
  fi
  if [[ -z "$run_id_trim" ]]; then
    return 0
  fi
  local agent_trim="$agent_in"
  if [[ -z "$agent_trim" ]]; then
    agent_trim="$(basename "$(dirname "$run_dir_trim")")"
  fi
  local key="${run_id_trim}|${run_dir_trim}"
  LAST_DISCOVERED_KEY="$key"
  if [[ -n "${KEY_SEEN[$key]:-}" ]]; then
    if [[ -z "${ASSIGNED_CHAT_URL[$key]:-}" ]] && [[ -n "${assigned_chat_in:-}" ]]; then
      ASSIGNED_CHAT_URL["$key"]="$assigned_chat_in"
    fi
    return 0
  fi

  KEY_SEEN["$key"]="1"
  ORDERED_KEYS+=("$key")
  AGENT_ID["$key"]="$agent_trim"
  RUN_ID["$key"]="$run_id_trim"
  RUN_DIR["$key"]="$run_dir_trim"
  ASSIGNED_CHAT_URL["$key"]="$assigned_chat_in"

  PID_FILE["$key"]="$run_dir_trim/$run_id_trim.pid"
  EXIT_FILE["$key"]="$run_dir_trim/$run_id_trim.exit"
  LAST_FILE["$key"]="$run_dir_trim/$run_id_trim.last.txt"
  RESULT_JSON["$key"]="$run_dir_trim/child_result.json"
  STATUS_FILE["$key"]="$run_dir_trim/$run_id_trim.status.log"
  LOG_FILE["$key"]="$run_dir_trim/$run_id_trim.log"

  STATE_CLASS["$key"]="UNKNOWN"
  STATE_REASON["$key"]="discovered"
  LEGACY_STATE["$key"]="pending"
  PID_VALUE["$key"]=""
  ALIVE["$key"]="0"
  EXIT_CODE["$key"]=""
  RESULT_STATUS["$key"]=""
  RESULT_EXIT["$key"]=""
  RESULT_PARSE_ERR["$key"]="0"
  LAST_STEP["$key"]=""
  LAST_TAIL["$key"]=""
  AGE_SEC["$key"]="0"
  LAST_UPDATE_EPOCH["$key"]="0"
  OBSERVED_CHAT_URL_BEFORE["$key"]=""
  OBSERVED_CHAT_URL_AFTER["$key"]=""
  ASSIGNED_CHAT_URL_NORM["$key"]=""
  OBSERVED_CHAT_URL_NORM["$key"]=""
  CHAT_PROOF["$key"]="unknown"
  RESULT_MTIME_CACHE["$key"]="0"
  PREV_CLASS["$key"]=""
  PREV_ASSIGNED_CHAT_URL_NORM["$key"]=""
  PREV_OBSERVED_CHAT_URL_NORM["$key"]=""
  PREV_CHAT_PROOF["$key"]=""
  log_event "event=child_discovered run_id=${run_id_trim} agent=${agent_trim} run_dir=${run_dir_trim}"
}

refresh_discovery() {
  local reg_bad_lines="0"
  local roster_bad_lines="0"
  local reg_count=0
  local roster_count=0
  local merged_count=0
  local missing_artifacts=0
  local -A reg_seen=()
  local -A roster_seen=()
  local -A merged_seen=()
  local -A missing_seen=()

  if [[ -d "$POOL_RUN_DIR/logs" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      add_child_run "" "$dir" "" ""
    done < <(find "$POOL_RUN_DIR/logs" -mindepth 2 -maxdepth 2 -type d | sort)
  fi

  if [[ -f "$REGISTRY_FILE" ]]; then
    while IFS=$'\t' read -r kind c1 c2 c3 c4 c5; do
      if [[ "$kind" == "META" ]] && [[ "$c1" == "bad_lines" ]]; then
        reg_bad_lines="${c2:-0}"
        continue
      fi
      if [[ "$kind" != "ROW" ]]; then
        continue
      fi
      add_child_run "$c1" "$c2" "$c3" "$c4"
      local key="${LAST_DISCOVERED_KEY:-}"
      if [[ -z "$key" ]]; then
        continue
      fi
      if [[ -z "${reg_seen[$key]:-}" ]]; then
        reg_seen["$key"]="1"
        reg_count=$((reg_count + 1))
      fi
      if [[ -z "${merged_seen[$key]:-}" ]]; then
        merged_seen["$key"]="1"
        merged_count=$((merged_count + 1))
      fi
      if [[ "${c5:-0}" == "1" ]] && [[ -z "${missing_seen[$key]:-}" ]]; then
        missing_seen["$key"]="1"
        missing_artifacts=$((missing_artifacts + 1))
      fi
    done < <(python3 - "$REGISTRY_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]
bad = 0
seen = set()
with open(path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            bad += 1
            continue
        run_dir = str(obj.get("run_dir", "")).strip()
        if not run_dir:
            bad += 1
            continue
        run_id = str(obj.get("run_id", "")).strip()
        if not run_id:
            run_id = os.path.basename(run_dir.rstrip("/"))
        agent_id = str(obj.get("agent_id", "")).strip()
        assigned_chat = str(obj.get("assigned_chat_url", "")).strip()
        missing = 0
        for field in ("result_json", "pid_file", "status_file", "log_file"):
            if not str(obj.get(field, "")).strip():
                missing = 1
                break
        key = (run_id, run_dir)
        if key in seen:
            continue
        seen.add(key)
        print(f"ROW\t{run_id}\t{run_dir}\t{agent_id}\t{assigned_chat}\t{missing}")
print(f"META\tbad_lines\t{bad}\t\t\t")
PY
)
    if [[ "$reg_bad_lines" =~ ^[0-9]+$ ]]; then
      if [[ "$reg_bad_lines" != "$registry_bad_lines_prev" ]] && (( reg_bad_lines > 0 )); then
        log_event "event=registry_warn code=W_LEDGER_CORRUPT_LINE_SKIPPED bad_lines=${reg_bad_lines} registry_file=${REGISTRY_FILE}"
      fi
      registry_bad_lines_prev="$reg_bad_lines"
    fi
  fi

  if [[ -f "$ROSTER_JSONL" ]]; then
    while IFS=$'\t' read -r kind c1 c2 c3 c4 c5; do
      if [[ "$kind" == "META" ]] && [[ "$c1" == "bad_lines" ]]; then
        roster_bad_lines="${c2:-0}"
        continue
      fi
      if [[ "$kind" != "ROW" ]]; then
        continue
      fi
      add_child_run "$c1" "$c2" "$c3" "$c4"
      local key="${LAST_DISCOVERED_KEY:-}"
      if [[ -z "$key" ]]; then
        continue
      fi
      if [[ -z "${roster_seen[$key]:-}" ]]; then
        roster_seen["$key"]="1"
        roster_count=$((roster_count + 1))
      fi
      if [[ -z "${merged_seen[$key]:-}" ]]; then
        merged_seen["$key"]="1"
        merged_count=$((merged_count + 1))
      fi
      if [[ "${c5:-0}" == "1" ]] && [[ -z "${missing_seen[$key]:-}" ]]; then
        missing_seen["$key"]="1"
        missing_artifacts=$((missing_artifacts + 1))
      fi
    done < <(python3 - "$ROSTER_JSONL" <<'PY'
import json
import os
import sys

path = sys.argv[1]
bad = 0
seen = set()
with open(path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            bad += 1
            continue
        run_dir = str(obj.get("run_dir", "")).strip()
        if not run_dir:
            bad += 1
            continue
        run_id = str(obj.get("run_id", "")).strip()
        if not run_id:
            run_id = os.path.basename(run_dir.rstrip("/"))
        agent_id = str(obj.get("agent_id", "")).strip()
        assigned_chat = str(obj.get("assigned_chat_url", "")).strip()
        missing = 0
        for field in ("result_json", "pid_file", "status_file", "log_file"):
            if not str(obj.get(field, "")).strip():
                missing = 1
                break
        key = (run_id, run_dir)
        if key in seen:
            continue
        seen.add(key)
        print(f"ROW\t{run_id}\t{run_dir}\t{agent_id}\t{assigned_chat}\t{missing}")
print(f"META\tbad_lines\t{bad}\t\t\t")
PY
)
    if [[ "$roster_bad_lines" =~ ^[0-9]+$ ]]; then
      if [[ "$roster_bad_lines" != "$roster_bad_lines_prev" ]] && (( roster_bad_lines > 0 )); then
        log_event "event=roster_warn code=W_FLEET_ROSTER_CORRUPT_LINE_SKIPPED bad_lines=${roster_bad_lines} roster_jsonl=${ROSTER_JSONL}"
      fi
      roster_bad_lines_prev="$roster_bad_lines"
    fi
  fi

  DISCOVERY_REGISTRY_COUNT="$reg_count"
  DISCOVERY_ROSTER_COUNT="$roster_count"
  DISCOVERY_MERGED_COUNT="$merged_count"
  MISSING_ARTIFACTS_TOTAL="$missing_artifacts"
}

refresh_result_cache() {
  local key="$1"
  local result_file="${RESULT_JSON[$key]}"
  if [[ ! -f "$result_file" ]]; then
    RESULT_STATUS["$key"]=""
    RESULT_EXIT["$key"]=""
    RESULT_PARSE_ERR["$key"]="0"
    OBSERVED_CHAT_URL_BEFORE["$key"]=""
    OBSERVED_CHAT_URL_AFTER["$key"]=""
    RESULT_MTIME_CACHE["$key"]="0"
    return 0
  fi

  local mtime
  mtime="$(file_mtime "$result_file")"
  if [[ "${RESULT_MTIME_CACHE[$key]:-0}" == "$mtime" ]]; then
    return 0
  fi
  RESULT_MTIME_CACHE["$key"]="$mtime"

  local parsed_status=""
  local parsed_exit=""
  local parsed_chat_before=""
  local parsed_chat_after=""
  mapfile -t parsed < <(python3 - "$result_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    obj = json.load(open(path, encoding="utf-8"))
except Exception:
    print("__PARSE_ERROR__")
    raise SystemExit(0)

status = str(obj.get("status", "") or "")
exit_code = obj.get("exit_code", "")
if isinstance(exit_code, int):
    exit_s = str(exit_code)
elif isinstance(exit_code, str):
    exit_s = exit_code.strip()
else:
    exit_s = ""

chat_before = str(obj.get("specialist_chat_url", "") or "")
chat_after = str(obj.get("pinned_route_url", "") or "")
print(status)
print(exit_s)
print(chat_before)
print(chat_after)
PY
)
  if [[ "${parsed[0]:-}" == "__PARSE_ERROR__" ]]; then
    RESULT_PARSE_ERR["$key"]="1"
    RESULT_STATUS["$key"]=""
    RESULT_EXIT["$key"]=""
    OBSERVED_CHAT_URL_BEFORE["$key"]=""
    OBSERVED_CHAT_URL_AFTER["$key"]=""
    return 0
  fi

  parsed_status="${parsed[0]:-}"
  parsed_exit="${parsed[1]:-}"
  parsed_chat_before="${parsed[2]:-}"
  parsed_chat_after="${parsed[3]:-}"

  RESULT_PARSE_ERR["$key"]="0"
  RESULT_STATUS["$key"]="$parsed_status"
  RESULT_EXIT["$key"]="$parsed_exit"
  OBSERVED_CHAT_URL_BEFORE["$key"]="$parsed_chat_before"
  OBSERVED_CHAT_URL_AFTER["$key"]="$parsed_chat_after"
}

classify_child() {
  local key="$1"
  local now_ts="$2"

  refresh_result_cache "$key"

  local pid_file="${PID_FILE[$key]}"
  local exit_file="${EXIT_FILE[$key]}"
  local status_file="${STATUS_FILE[$key]}"
  local log_file="${LOG_FILE[$key]}"
  local last_file="${LAST_FILE[$key]}"
  local run_dir="${RUN_DIR[$key]}"

  local pid=""
  pid="$(read_pid "$pid_file")"
  local alive=0
  if is_alive_pid "$pid"; then
    alive=1
  fi
  PID_VALUE["$key"]="$pid"
  ALIVE["$key"]="$alive"

  local exit_code=""
  if [[ -f "$exit_file" ]]; then
    exit_code="$(tr -d '[:space:]' <"$exit_file" 2>/dev/null || true)"
  fi
  EXIT_CODE["$key"]="$exit_code"

  local step_line=""
  if [[ -f "$status_file" ]]; then
    step_line="$(tail -n 1 "$status_file" 2>/dev/null || true)"
  elif [[ -f "$log_file" ]]; then
    step_line="$(tail -n 1 "$log_file" 2>/dev/null || true)"
  fi
  local step=""
  step="$(printf '%s' "$step_line" | sed -n 's/.*step=\([^[:space:]]*\).*/\1/p' | head -n 1 || true)"
  LAST_STEP["$key"]="$step"

  local last_tail=""
  if [[ -f "$last_file" ]]; then
    last_tail="$(tail -n 1 "$last_file" 2>/dev/null || true)"
  fi
  LAST_TAIL["$key"]="$(short_line "$last_tail")"

  local m_status m_log m_last m_result m_exit m_max
  m_status="$(file_mtime "$status_file")"
  m_log="$(file_mtime "$log_file")"
  m_last="$(file_mtime "$last_file")"
  m_result="$(file_mtime "${RESULT_JSON[$key]}")"
  m_exit="$(file_mtime "$exit_file")"
  m_max="$m_status"
  for candidate in "$m_log" "$m_last" "$m_result" "$m_exit"; do
    if (( candidate > m_max )); then
      m_max="$candidate"
    fi
  done
  LAST_UPDATE_EPOCH["$key"]="$m_max"
  local age=0
  if (( m_max > 0 )) && (( now_ts >= m_max )); then
    age=$((now_ts - m_max))
  fi
  AGE_SEC["$key"]="$age"

  local klass="UNKNOWN"
  local reason="awaiting_artifacts"
  local result_exit="${RESULT_EXIT[$key]}"
  local parse_err="${RESULT_PARSE_ERR[$key]}"

  if [[ -f "$exit_file" ]]; then
    if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
      if [[ "$exit_code" == "0" ]]; then
        klass="DONE_OK"
        reason="exit_file_zero"
      else
        klass="DONE_FAIL"
        reason="exit_file_nonzero"
      fi
    elif [[ "$result_exit" =~ ^-?[0-9]+$ ]]; then
      if [[ "$result_exit" == "0" ]]; then
        klass="DONE_OK"
        reason="result_json_zero_no_exit_parse"
      else
        klass="DONE_FAIL"
        reason="result_json_nonzero_no_exit_parse"
      fi
    else
      klass="DONE_FAIL"
      reason="exit_file_invalid"
    fi
  elif [[ "$result_exit" =~ ^-?[0-9]+$ ]] && (( alive == 0 )); then
    if [[ "$result_exit" == "0" ]]; then
      klass="DONE_OK"
      reason="result_json_zero_no_exit_file"
    else
      klass="DONE_FAIL"
      reason="result_json_nonzero_no_exit_file"
    fi
  elif (( alive == 1 )); then
    if (( age > STUCK_AFTER_SEC )); then
      klass="STUCK"
      reason="no_progress_${age}s"
    else
      klass="RUNNING"
      reason="pid_alive"
    fi
  elif [[ -n "$pid" ]]; then
    klass="ORPHANED"
    reason="dead_pid_no_terminal_artifacts"
  elif [[ ! -d "$run_dir" ]]; then
    klass="ORPHANED"
    reason="run_dir_missing"
  fi

  if [[ "$parse_err" == "1" ]]; then
    reason="${reason},result_json_partial"
  fi

  STATE_CLASS["$key"]="$klass"
  STATE_REASON["$key"]="$reason"
  RESULT_STATUS["$key"]="${RESULT_STATUS[$key]:-}"
  RESULT_EXIT["$key"]="${RESULT_EXIT[$key]:-}"

  local legacy="pending"
  case "$klass" in
    DONE_OK) legacy="done" ;;
    DONE_FAIL|ORPHANED) legacy="failed" ;;
    RUNNING|STUCK) legacy="running" ;;
    UNKNOWN) legacy="pending" ;;
  esac
  LEGACY_STATE["$key"]="$legacy"

  local assigned_norm=""
  local observed_norm=""
  local observed_candidate=""
  assigned_norm="$(normalize_chat_url "${ASSIGNED_CHAT_URL[$key]:-}")"
  if [[ -n "${OBSERVED_CHAT_URL_AFTER[$key]:-}" ]]; then
    observed_candidate="${OBSERVED_CHAT_URL_AFTER[$key]}"
  elif [[ -n "${OBSERVED_CHAT_URL_BEFORE[$key]:-}" ]]; then
    observed_candidate="${OBSERVED_CHAT_URL_BEFORE[$key]}"
  else
    observed_candidate="$(extract_evidence_chat_url "${LOG_FILE[$key]}")"
  fi
  observed_norm="$(normalize_chat_url "$observed_candidate")"

  local proof="unknown"
  if [[ -n "$assigned_norm" ]] && [[ -n "$observed_norm" ]]; then
    if [[ "$assigned_norm" == "$observed_norm" ]]; then
      proof="ok"
    else
      proof="mismatch"
    fi
  fi
  ASSIGNED_CHAT_URL_NORM["$key"]="$assigned_norm"
  OBSERVED_CHAT_URL_NORM["$key"]="$observed_norm"
  CHAT_PROOF["$key"]="$proof"

  if [[ "${PREV_CHAT_PROOF[$key]:-}" != "$proof" ]] \
    || [[ "${PREV_ASSIGNED_CHAT_URL_NORM[$key]:-}" != "$assigned_norm" ]] \
    || [[ "${PREV_OBSERVED_CHAT_URL_NORM[$key]:-}" != "$observed_norm" ]]; then
    log_event "event=chat_proof run_id=${RUN_ID[$key]} proof=${proof} assigned=${assigned_norm:-none} observed=${observed_norm:-none}"
    PREV_CHAT_PROOF["$key"]="$proof"
    PREV_ASSIGNED_CHAT_URL_NORM["$key"]="$assigned_norm"
    PREV_OBSERVED_CHAT_URL_NORM["$key"]="$observed_norm"
  fi

  if [[ "${PREV_CLASS[$key]:-}" != "$klass" ]]; then
    append_transition_event "$key" "${PREV_CLASS[$key]:-}" "$klass" "$reason" "$step"
    PREV_CLASS["$key"]="$klass"
    log_event "event=child_state agent=${AGENT_ID[$key]} run_id=${RUN_ID[$key]} class=${klass} reason=${reason} pid=${pid:-none} alive=${alive} age_sec=${age}"
    if [[ "$klass" == "DONE_OK" ]]; then
      log_event "event=child_done agent=${AGENT_ID[$key]} run_id=${RUN_ID[$key]} exit_code=${exit_code:-${result_exit:-none}} result_status=${RESULT_STATUS[$key]:-none} last_tail=\"${LAST_TAIL[$key]}\""
    elif [[ "$klass" == "DONE_FAIL" || "$klass" == "ORPHANED" ]]; then
      log_event "event=child_failed agent=${AGENT_ID[$key]} run_id=${RUN_ID[$key]} class=${klass} exit_code=${exit_code:-${result_exit:-none}} result_status=${RESULT_STATUS[$key]:-none} last_tail=\"${LAST_TAIL[$key]}\""
    fi
  fi
}

write_snapshot() {
  local total="$1"
  local done_ok="$2"
  local done_fail="$3"
  local running="$4"
  local stuck="$5"
  local orphaned="$6"
  local unknown="$7"
  local disk_status="$8"
  local disk_free_pct="$9"
  local disk_avail_kb="${10}"
  local discovery_registry="${11}"
  local discovery_roster="${12}"
  local discovery_merged="${13}"
  local missing_artifacts_total="${14}"

  local tmp_rows
  tmp_rows="$(mktemp)"
  for key in "${ORDERED_KEYS[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$key" \
      "${AGENT_ID[$key]}" \
      "${RUN_ID[$key]}" \
      "${RUN_DIR[$key]}" \
      "${STATE_CLASS[$key]}" \
      "${LEGACY_STATE[$key]}" \
      "$(short_line "${STATE_REASON[$key]}")" \
      "${PID_VALUE[$key]}" \
      "${ALIVE[$key]}" \
      "${EXIT_CODE[$key]}" \
      "$(short_line "${RESULT_STATUS[$key]}")" \
      "$(short_line "${RESULT_EXIT[$key]}")" \
      "${RESULT_PARSE_ERR[$key]}" \
      "$(short_line "${LAST_STEP[$key]}")" \
      "$(short_line "${LAST_TAIL[$key]}")" \
      "${AGE_SEC[$key]}" \
      "$(short_line "${ASSIGNED_CHAT_URL[$key]}")" \
      "$(short_line "${OBSERVED_CHAT_URL_BEFORE[$key]}")" \
      "$(short_line "${OBSERVED_CHAT_URL_AFTER[$key]}")" \
      "$(short_line "${ASSIGNED_CHAT_URL_NORM[$key]}")" \
      "$(short_line "${OBSERVED_CHAT_URL_NORM[$key]}")" \
      "$(short_line "${CHAT_PROOF[$key]}")" \
      "${PID_FILE[$key]}" \
      "${EXIT_FILE[$key]}" \
      "${STATUS_FILE[$key]}" \
      "${LOG_FILE[$key]}" \
      "${LAST_FILE[$key]}" \
      "${RESULT_JSON[$key]}" \
      "${LAST_UPDATE_EPOCH[$key]}" \
      "$(now_iso)" >>"$tmp_rows"
  done

  python3 - "$tmp_rows" "$SUMMARY_JSON" "$SUMMARY_CSV" "$REGISTRY_FILE" "$ROSTER_JSONL" \
    "$total" "$done_ok" "$done_fail" "$running" "$stuck" "$orphaned" "$unknown" \
    "$disk_status" "$disk_free_pct" "$disk_avail_kb" \
    "$discovery_registry" "$discovery_roster" "$discovery_merged" "$missing_artifacts_total" \
    "${CODEX_SWARM_STATUS_JSON:-}" <<'PY'
import csv
import json
import os
import sys

rows_file, json_out, csv_out, registry_file, roster_file = sys.argv[1:6]
total, done_ok, done_fail, running, stuck, orphaned, unknown = map(int, sys.argv[6:13])
disk_status = str(sys.argv[13] or "unknown")
disk_free_pct_raw = str(sys.argv[14] or "").strip()
disk_avail_kb_raw = str(sys.argv[15] or "").strip()
discovery_registry = int(sys.argv[16])
discovery_roster = int(sys.argv[17])
discovery_merged = int(sys.argv[18])
missing_artifacts_total = int(sys.argv[19])
codex_swarm_json = str(sys.argv[20] or "").strip()

disk_free_pct = int(disk_free_pct_raw) if disk_free_pct_raw.isdigit() else None
disk_avail_kb = int(disk_avail_kb_raw) if disk_avail_kb_raw.isdigit() else None

agents = []
with open(rows_file, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 30:
            continue
        (
            key,
            agent_id,
            run_id,
            run_dir,
            status_class,
            legacy_state,
            reason,
            pid,
            alive,
            exit_code,
            result_status,
            result_exit,
            parse_err,
            last_step,
            last_tail,
            age_sec,
            assigned_chat_url,
            observed_chat_url_before,
            observed_chat_url_after,
            assigned_chat_url_norm,
            observed_chat_url_norm,
            chat_proof,
            pid_file,
            exit_file,
            status_file,
            log_file,
            last_file,
            result_json,
            last_update_epoch,
            snapshot_ts,
        ) = parts
        agents.append(
            {
                "key": key,
                "agent_id": agent_id,
                "run_id": run_id,
                "run_dir": run_dir,
                "state_class": status_class,
                "state": legacy_state,
                "reason": reason,
                "pid": int(pid) if pid.isdigit() else None,
                "alive": alive == "1",
                "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else None,
                "result_status": result_status or None,
                "result_exit": int(result_exit) if result_exit.lstrip("-").isdigit() else None,
                "result_parse_error": parse_err == "1",
                "last_step": last_step or None,
                "last_tail": last_tail or None,
                "age_sec": int(age_sec) if age_sec.isdigit() else None,
                "assigned_chat_url": assigned_chat_url or None,
                "observed_chat_url_before": observed_chat_url_before or None,
                "observed_chat_url_after": observed_chat_url_after or None,
                "assigned_chat_url_norm": assigned_chat_url_norm or None,
                "observed_chat_url_norm": observed_chat_url_norm or None,
                "chat_proof": chat_proof or "unknown",
                "pid_file": pid_file,
                "exit_file": exit_file,
                "status_file": status_file,
                "log_file": log_file,
                "last_file": last_file,
                "result_json": result_json,
                "last_update_epoch": int(last_update_epoch) if last_update_epoch.isdigit() else None,
                "snapshot_ts": snapshot_ts,
            }
        )

payload = {
    "total": total,
    "done": done_ok,
    "failed": done_fail + orphaned,
    "running": running + stuck,
    "pending": unknown,
    "done_ok": done_ok,
    "done_fail": done_fail,
    "stuck": stuck,
    "orphaned": orphaned,
    "unknown": unknown,
    "disk_status": disk_status,
    "disk_free_pct": disk_free_pct,
    "disk_avail_kb": disk_avail_kb,
    "registry_file": registry_file,
    "roster_jsonl": roster_file,
    "discovery_sources": {
        "registry": discovery_registry,
        "roster": discovery_roster,
        "merged": discovery_merged,
    },
    "missing_artifacts_total": missing_artifacts_total,
    "chat_ok_total": sum(1 for r in agents if r.get("chat_proof") == "ok"),
    "chat_mismatch_total": sum(1 for r in agents if r.get("chat_proof") == "mismatch"),
    "chat_unknown_total": sum(1 for r in agents if r.get("chat_proof") == "unknown"),
    "agents": agents,
}

json_tmp = f"{json_out}.tmp.{os.getpid()}"
with open(json_tmp, "w", encoding="utf-8") as out:
    json.dump(payload, out, ensure_ascii=False, indent=2)
    out.write("\n")
os.replace(json_tmp, json_out)

csv_tmp = f"{csv_out}.tmp.{os.getpid()}"
header = [
    "agent_id",
    "run_id",
    "state_class",
    "state",
    "reason",
    "pid",
    "alive",
    "exit_code",
    "result_status",
    "result_exit",
    "result_parse_error",
    "last_step",
    "last_tail",
    "age_sec",
    "assigned_chat_url",
    "observed_chat_url_before",
    "observed_chat_url_after",
    "assigned_chat_url_norm",
    "observed_chat_url_norm",
    "chat_proof",
    "run_dir",
    "pid_file",
    "exit_file",
    "status_file",
    "log_file",
    "last_file",
    "result_json",
]
with open(csv_tmp, "w", encoding="utf-8", newline="") as out:
    w = csv.DictWriter(out, fieldnames=header)
    w.writeheader()
    for row in agents:
        w.writerow({k: row.get(k) for k in header})
os.replace(csv_tmp, csv_out)

if codex_swarm_json:
    def map_state(row):
        klass = str((row.get("state_class") or "")).upper()
        if klass == "DONE_OK":
            return "done"
        if klass in ("DONE_FAIL", "ORPHANED"):
            return "failed"
        if klass in ("RUNNING", "STUCK"):
            return "running"
        return "waiting"

    codex_agents = []
    for row in agents:
        state = map_state(row)
        task = row.get("last_step") or row.get("reason") or row.get("last_tail")
        task = (task or "").strip() or None
        result = row.get("result_status") or None
        codex_agents.append(
            {
                "id": row.get("agent_id") or row.get("key") or "agent",
                "name": row.get("agent_id") or row.get("key") or "agent",
                "state": state,
                "task": task,
                "result": result,
                "run_id": row.get("run_id"),
                "updated_at": row.get("snapshot_ts"),
            }
        )

    codex_payload = {
        "version": "swarm-status.v1",
        "updated_at": agents[0].get("snapshot_ts") if agents else None,
        "source": {
            "type": "child_fleet_monitor",
            "fleet_summary_json": json_out,
            "registry_file": registry_file,
            "roster_jsonl": roster_file,
        },
        "summary": {
            "total": total,
            "running": running + stuck,
            "done": done_ok,
            "failed": done_fail + orphaned,
            "waiting": unknown,
            "done_ok": done_ok,
            "done_fail": done_fail,
            "stuck": stuck,
            "orphaned": orphaned,
            "unknown": unknown,
        },
        "agents": codex_agents,
    }

    codex_tmp = f"{codex_swarm_json}.tmp.{os.getpid()}"
    with open(codex_tmp, "w", encoding="utf-8") as out:
        json.dump(codex_payload, out, ensure_ascii=False, indent=2)
        out.write("\n")
    os.replace(codex_tmp, codex_swarm_json)
PY

  rm -f "$tmp_rows" >/dev/null 2>&1 || true
}

start_epoch="$(now_epoch)"
next_heartbeat_epoch=0
if (( HEARTBEAT_SEC > 0 )); then
  write_heartbeat
  next_heartbeat_epoch=$((start_epoch + HEARTBEAT_SEC))
fi
last_progress_sig=""

log_event "event=start poll_sec=${POLL_SEC} heartbeat_sec=${HEARTBEAT_SEC} timeout_sec=${TIMEOUT_SEC} stuck_after_sec=${STUCK_AFTER_SEC} registry_file=${REGISTRY_FILE} roster_jsonl=${ROSTER_JSONL} heartbeat_file=${HEARTBEAT_FILE} events_jsonl=${EVENTS_JSONL} disk_path=${FLEET_DISK_PATH} disk_warn_pct=${FLEET_DISK_FREE_WARN_PCT} disk_fail_pct=${FLEET_DISK_FREE_FAIL_PCT} codex_swarm_status_json=${CODEX_SWARM_STATUS_JSON:-none}"

while true; do
  now_ts="$(now_epoch)"
  refresh_disk_status
  refresh_discovery

  total="${#ORDERED_KEYS[@]}"
  done_ok=0
  done_fail=0
  running=0
  stuck=0
  orphaned=0
  unknown=0

  for key in "${ORDERED_KEYS[@]}"; do
    classify_child "$key" "$now_ts"
    case "${STATE_CLASS[$key]}" in
      DONE_OK) ((done_ok+=1)) ;;
      DONE_FAIL) ((done_fail+=1)) ;;
      RUNNING) ((running+=1)) ;;
      STUCK) ((stuck+=1)) ;;
      ORPHANED) ((orphaned+=1)) ;;
      *) ((unknown+=1)) ;;
    esac
  done

  write_snapshot "$total" "$done_ok" "$done_fail" "$running" "$stuck" "$orphaned" "$unknown" "${DISK_STATUS:-unknown}" "${DISK_FREE_PCT:-}" "${DISK_AVAIL_KB:-}" "${DISCOVERY_REGISTRY_COUNT:-0}" "${DISCOVERY_ROSTER_COUNT:-0}" "${DISCOVERY_MERGED_COUNT:-0}" "${MISSING_ARTIFACTS_TOTAL:-0}"

  progress_sig="${total}|${done_ok}|${done_fail}|${running}|${stuck}|${orphaned}|${unknown}"
  if [[ "$progress_sig" != "$last_progress_sig" ]]; then
    log_event "event=progress total=${total} done_ok=${done_ok} done_fail=${done_fail} running=${running} stuck=${stuck} orphaned=${orphaned} unknown=${unknown} disk_status=${DISK_STATUS:-unknown} disk_free_pct=${DISK_FREE_PCT:-none}"
    last_progress_sig="$progress_sig"
  fi

  if (( total > 0 )) && (( running == 0 )) && (( stuck == 0 )) && (( unknown == 0 )); then
    log_event "event=done total=${total} ok=${done_ok} failed=${done_fail} orphaned=${orphaned} disk_status=${DISK_STATUS:-unknown} disk_free_pct=${DISK_FREE_PCT:-none} summary_json=${SUMMARY_JSON} summary_csv=${SUMMARY_CSV}"
    if (( done_fail + orphaned > 0 )); then
      exit 1
    fi
    exit 0
  fi

  if (( HEARTBEAT_SEC > 0 )) && (( now_ts >= next_heartbeat_epoch )); then
    write_heartbeat
    log_event "event=heartbeat total=${total} done_ok=${done_ok} done_fail=${done_fail} running=${running} stuck=${stuck} orphaned=${orphaned} unknown=${unknown} disk_status=${DISK_STATUS:-unknown} disk_free_pct=${DISK_FREE_PCT:-none}"
    next_heartbeat_epoch=$((now_ts + HEARTBEAT_SEC))
  fi

  if (( TIMEOUT_SEC > 0 )) && (( now_ts - start_epoch >= TIMEOUT_SEC )); then
    log_event "event=timeout elapsed_sec=$((now_ts - start_epoch)) total=${total} done_ok=${done_ok} done_fail=${done_fail} running=${running} stuck=${stuck} orphaned=${orphaned} unknown=${unknown} disk_status=${DISK_STATUS:-unknown} disk_free_pct=${DISK_FREE_PCT:-none} summary_json=${SUMMARY_JSON} summary_csv=${SUMMARY_CSV}"
    exit 124
  fi

  sleep "$POLL_SEC"
done
