#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/child_run_monitor.sh --run-dir DIR --run-id ID [options]

Required:
  --run-dir DIR
  --run-id ID

Options:
  --label TEXT
  --poll-sec N          (default: 2)
  --heartbeat-sec N     (default: 20, 0 disables heartbeats)
  --timeout-sec N       (default: 0, disabled)
  --pid-file FILE       (optional, write monitor PID to this file)
  --monitor-log FILE    (default: <run-dir>/<run-id>.monitor.log)
  --stdout              (mirror monitor events to stdout)
  -h, --help
USAGE
}

RUN_DIR=""
RUN_ID=""
LABEL=""
POLL_SEC=2
HEARTBEAT_SEC=20
TIMEOUT_SEC=0
MONITOR_LOG=""
TO_STDOUT=0
OUT_PID_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --poll-sec) POLL_SEC="${2:-}"; shift 2 ;;
    --heartbeat-sec) HEARTBEAT_SEC="${2:-}"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --pid-file) OUT_PID_FILE="${2:-}"; shift 2 ;;
    --monitor-log) MONITOR_LOG="${2:-}"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$RUN_DIR" || -z "$RUN_ID" ]]; then
  usage >&2
  exit 2
fi
for n in "$POLL_SEC" "$HEARTBEAT_SEC" "$TIMEOUT_SEC"; do
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
if [[ ! -d "$RUN_DIR" ]]; then
  echo "run dir not found: $RUN_DIR" >&2
  exit 2
fi
if [[ -z "$MONITOR_LOG" ]]; then
  MONITOR_LOG="$RUN_DIR/$RUN_ID.monitor.log"
fi
if [[ -n "$OUT_PID_FILE" ]]; then
  mkdir -p "$(dirname "$OUT_PID_FILE")"
  printf '%s\n' "$$" >"$OUT_PID_FILE"
fi

STATUS_FILE="$RUN_DIR/$RUN_ID.status.log"
EXIT_FILE="$RUN_DIR/$RUN_ID.exit"
PID_FILE="$RUN_DIR/$RUN_ID.pid"
LAST_FILE="$RUN_DIR/$RUN_ID.last.txt"
RESULT_JSON="$RUN_DIR/child_result.json"

mkdir -p "$(dirname "$MONITOR_LOG")"

now_iso() {
  date -Iseconds
}

short_line() {
  local line="$1"
  line="$(printf '%s' "$line" | tr '\r' ' ' | tr '\n' ' ')"
  line="$(printf '%s' "$line" | sed 's/[[:space:]]\+/ /g')"
  printf '%s' "$line" | cut -c1-240
}

log_event() {
  local msg="$1"
  local prefix="[monitor] ts=$(now_iso) run_id=${RUN_ID}"
  if [[ -n "$LABEL" ]]; then
    prefix="${prefix} label=${LABEL}"
  fi
  local line="${prefix} ${msg}"
  printf '%s\n' "$line" >>"$MONITOR_LOG"
  if [[ "$TO_STDOUT" == "1" ]]; then
    printf '%s\n' "$line"
  fi
}

read_pid() {
  if [[ -f "$PID_FILE" ]]; then
    tr -d '[:space:]' <"$PID_FILE" 2>/dev/null || true
  fi
}

is_alive_pid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

start_epoch="$(date +%s)"
last_status_line=""
next_heartbeat_epoch=0
if (( HEARTBEAT_SEC > 0 )); then
  next_heartbeat_epoch=$((start_epoch + HEARTBEAT_SEC))
fi
dead_without_exit_reported=0

log_event "event=start poll_sec=${POLL_SEC} heartbeat_sec=${HEARTBEAT_SEC} timeout_sec=${TIMEOUT_SEC} run_dir=${RUN_DIR}"

while true; do
  now_epoch="$(date +%s)"
  pid="$(read_pid)"
  alive=0
  if is_alive_pid "$pid"; then
    alive=1
    dead_without_exit_reported=0
  fi

  if [[ -f "$STATUS_FILE" ]]; then
    cur_status_line="$(tail -n 1 "$STATUS_FILE" 2>/dev/null || true)"
    if [[ -n "$cur_status_line" && "$cur_status_line" != "$last_status_line" ]]; then
      last_status_line="$cur_status_line"
      log_event "event=status alive=${alive} pid=${pid:-none} tail=\"$(short_line "$cur_status_line")\""
    fi
  fi

  if [[ -f "$EXIT_FILE" ]]; then
    exit_code="$(tr -d '[:space:]' <"$EXIT_FILE" 2>/dev/null || true)"
    result_status=""
    result_exit=""
    if [[ -f "$RESULT_JSON" ]]; then
      readarray -t result_meta < <(python3 - "$RESULT_JSON" <<'PY'
import json
import sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
print(obj.get("status", ""))
print(obj.get("exit_code", ""))
PY
)
      result_status="${result_meta[0]:-}"
      result_exit="${result_meta[1]:-}"
    fi
    last_tail=""
    if [[ -f "$LAST_FILE" ]]; then
      last_tail="$(tail -n 1 "$LAST_FILE" 2>/dev/null || true)"
    fi
    log_event "event=done exit_code=${exit_code:-none} result_status=${result_status:-none} result_exit=${result_exit:-none} last_tail=\"$(short_line "$last_tail")\""
    exit 0
  fi

  if [[ "$alive" == "0" ]] && [[ -n "$pid" ]] && [[ "$dead_without_exit_reported" == "0" ]]; then
    log_event "event=pid_not_alive pid=${pid} exit_file=missing"
    dead_without_exit_reported=1
  fi

  if (( HEARTBEAT_SEC > 0 )) && (( now_epoch >= next_heartbeat_epoch )); then
    log_event "event=heartbeat alive=${alive} pid=${pid:-none} exit_file=missing"
    next_heartbeat_epoch=$((now_epoch + HEARTBEAT_SEC))
  fi

  if (( TIMEOUT_SEC > 0 )) && (( now_epoch - start_epoch >= TIMEOUT_SEC )); then
    log_event "event=timeout elapsed_sec=$((now_epoch - start_epoch))"
    exit 124
  fi

  sleep "$POLL_SEC"
done
