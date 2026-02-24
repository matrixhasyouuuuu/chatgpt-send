#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/fleet_follow.sh [--summary-json FILE | --pool-run-dir DIR] [options]

Required:
  --summary-json FILE        path to fleet.summary.json
  --pool-run-dir DIR         shorthand for <DIR>/fleet.summary.json

Options:
  --tick-ms N                poll interval in milliseconds (default: 1000)
  --pid-file FILE            write follower pid (removed on exit)
  --log FILE                 append rendered lines to FILE
  --once                     render one snapshot and exit
  --no-ansi                  disable ANSI colors
  -h, --help
USAGE
}

POOL_RUN_DIR=""
SUMMARY_JSON=""
TICK_MS=1000
PID_FILE=""
LOG_FILE=""
ONCE=0
NO_ANSI=0
NO_ANSI_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-run-dir) POOL_RUN_DIR="${2:-}"; shift 2 ;;
    --summary-json) SUMMARY_JSON="${2:-}"; shift 2 ;;
    --tick-ms) TICK_MS="${2:-}"; shift 2 ;;
    --pid-file) PID_FILE="${2:-}"; shift 2 ;;
    --log) LOG_FILE="${2:-}"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --no-ansi) NO_ANSI=1; NO_ANSI_SET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SUMMARY_JSON" && -z "$POOL_RUN_DIR" ]]; then
  usage >&2
  exit 2
fi
if [[ -z "$SUMMARY_JSON" ]]; then
  SUMMARY_JSON="$POOL_RUN_DIR/fleet.summary.json"
fi
if [[ -z "$POOL_RUN_DIR" ]]; then
  POOL_RUN_DIR="$(dirname "$SUMMARY_JSON")"
fi
EARLY_ABORT_FLAG="$POOL_RUN_DIR/.early_abort"
EARLY_ABORT_REASON_FILE="$POOL_RUN_DIR/.early_abort.reason"
if [[ ! "$TICK_MS" =~ ^[0-9]+$ ]] || (( TICK_MS < 50 )); then
  echo "--tick-ms must be an integer >= 50" >&2
  exit 2
fi
if [[ "$NO_ANSI_SET" == "0" ]]; then
  if [[ ! -t 1 || "${TERM:-}" == "dumb" ]]; then
    NO_ANSI=1
  fi
fi

if [[ -n "$PID_FILE" ]]; then
  mkdir -p "$(dirname "$PID_FILE")"
  printf '%s\n' "$$" >"$PID_FILE"
fi
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
fi

cleanup() {
  if [[ -n "$PID_FILE" ]]; then
    rm -f "$PID_FILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

render_line() {
  local line="$1"
  printf '%s\n' "$line"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

colorize_line() {
  local state="$1"
  local line="$2"
  if [[ "$NO_ANSI" == "1" ]]; then
    printf '%s' "$line"
    return 0
  fi
  local c_reset=$'\033[0m'
  local c_green=$'\033[32m'
  local c_red=$'\033[31m'
  local c_yellow=$'\033[33m'
  case "$state" in
    ok) printf '%s%s%s' "$c_green" "$line" "$c_reset" ;;
    fail) printf '%s%s%s' "$c_red" "$line" "$c_reset" ;;
    wait|invalid|running) printf '%s%s%s' "$c_yellow" "$line" "$c_reset" ;;
    *) printf '%s' "$line" ;;
  esac
}

read_snapshot() {
  python3 - "$SUMMARY_JSON" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("STATE=missing")
    raise SystemExit(0)

try:
    obj = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("STATE=invalid")
    raise SystemExit(0)

def as_int(key, default=0):
    try:
        return int(obj.get(key, default))
    except Exception:
        return int(default)

total = as_int("total", 0)
done_ok = as_int("done_ok", as_int("done", 0))
done_fail = as_int("done_fail", 0)
running = as_int("running", 0)
stuck = as_int("stuck", 0)
orphaned = as_int("orphaned", 0)
unknown = as_int("unknown", as_int("pending", 0))
done = done_ok + done_fail + orphaned
failed = done_fail + orphaned
pending = running + stuck + unknown
disk_status = str(obj.get("disk_status", "unknown") or "unknown")
disk_free_pct_raw = obj.get("disk_free_pct")
try:
    disk_free_pct = int(disk_free_pct_raw) if disk_free_pct_raw is not None else None
except Exception:
    disk_free_pct = None
chat_ok_total = as_int("chat_ok_total", 0)
chat_mismatch_total = as_int("chat_mismatch_total", 0)
chat_unknown_total = as_int("chat_unknown_total", 0)
done_flag = 1 if total > 0 and pending == 0 else 0
fail_flag = 1 if failed > 0 else 0
status = "ok"
if done_flag == 1 and fail_flag == 1:
    status = "fail"
elif done_flag == 0:
    status = "running"

disk_sig = "none" if disk_free_pct is None else str(disk_free_pct)
sig = (
    f"{total}|{done_ok}|{done_fail}|{running}|{stuck}|{orphaned}|{unknown}|"
    f"{disk_status}|{disk_sig}|{chat_ok_total}|{chat_mismatch_total}|{chat_unknown_total}"
)

print("STATE=ok")
print(f"TOTAL={total}")
print(f"DONE_OK={done_ok}")
print(f"DONE_FAIL={done_fail}")
print(f"RUNNING={running}")
print(f"STUCK={stuck}")
print(f"ORPHANED={orphaned}")
print(f"UNKNOWN={unknown}")
print(f"DONE={done}")
print(f"FAILED={failed}")
print(f"PENDING={pending}")
print(f"DISK_STATUS={disk_status}")
print(f"DISK_FREE_PCT={disk_sig}")
print(f"CHAT_OK_TOTAL={chat_ok_total}")
print(f"CHAT_MISMATCH_TOTAL={chat_mismatch_total}")
print(f"CHAT_UNKNOWN_TOTAL={chat_unknown_total}")
print(f"DONE_FLAG={done_flag}")
print(f"FAIL_FLAG={fail_flag}")
print(f"STATUS={status}")
print(f"SIG={sig}")
PY
}

last_sig=""
last_early_abort_reason=""
tick_sec="$(python3 - "$TICK_MS" <<'PY'
import sys
print(max(int(sys.argv[1]), 1) / 1000.0)
PY
)"

while true; do
  state="missing"
  total=0
  done_ok=0
  done_fail=0
  running=0
  stuck=0
  orphaned=0
  unknown=0
  done=0
  failed=0
  pending=0
  disk_status="unknown"
  disk_free_pct="none"
  chat_ok_total=0
  chat_mismatch_total=0
  chat_unknown_total=0
  done_flag=0
  fail_flag=0
  status="wait"
  sig="none"
  early_abort=0
  early_abort_reason="none"
  early_abort_event=""

  while IFS='=' read -r key value; do
    case "$key" in
      STATE) state="$value" ;;
      TOTAL) total="$value" ;;
      DONE_OK) done_ok="$value" ;;
      DONE_FAIL) done_fail="$value" ;;
      RUNNING) running="$value" ;;
      STUCK) stuck="$value" ;;
      ORPHANED) orphaned="$value" ;;
      UNKNOWN) unknown="$value" ;;
      DONE) done="$value" ;;
      FAILED) failed="$value" ;;
      PENDING) pending="$value" ;;
      DISK_STATUS) disk_status="$value" ;;
      DISK_FREE_PCT) disk_free_pct="$value" ;;
      CHAT_OK_TOTAL) chat_ok_total="$value" ;;
      CHAT_MISMATCH_TOTAL) chat_mismatch_total="$value" ;;
      CHAT_UNKNOWN_TOTAL) chat_unknown_total="$value" ;;
      DONE_FLAG) done_flag="$value" ;;
      FAIL_FLAG) fail_flag="$value" ;;
      STATUS) status="$value" ;;
      SIG) sig="$value" ;;
    esac
  done < <(read_snapshot)

  if [[ -f "$EARLY_ABORT_FLAG" ]]; then
    early_abort=1
    if [[ -f "$EARLY_ABORT_REASON_FILE" ]]; then
      early_abort_reason="$(tr '\n' ' ' <"$EARLY_ABORT_REASON_FILE" | sed -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]*$//')"
    else
      early_abort_reason="reason=unknown"
    fi
    early_abort_event="${early_abort_reason}"
  fi

  ts="$(date -Iseconds)"
  if [[ "$state" == "missing" ]]; then
    line="FLEET_FOLLOW_WAIT ts=$ts reason=summary_missing path=$SUMMARY_JSON"
    render_line "$(colorize_line wait "$line")"
    if [[ "$ONCE" == "1" ]]; then
      exit 0
    fi
    sleep "$tick_sec"
    continue
  fi
  if [[ "$state" == "invalid" ]]; then
    line="FLEET_FOLLOW_WAIT ts=$ts reason=summary_invalid path=$SUMMARY_JSON"
    render_line "$(colorize_line invalid "$line")"
    if [[ "$ONCE" == "1" ]]; then
      exit 0
    fi
    sleep "$tick_sec"
    continue
  fi

  if [[ "$sig" != "$last_sig" ]] || [[ "$ONCE" == "1" ]]; then
    line="PROGRESS ts=$ts total=$total ok=$done_ok fail=$failed running=$running stuck=$stuck orphaned=$orphaned unknown=$unknown pending=$pending chat_ok=$chat_ok_total chat_mismatch=$chat_mismatch_total chat_unknown=$chat_unknown_total disk=${disk_status}/${disk_free_pct} status=$status early_abort=$early_abort"
    if [[ "$early_abort_event" != "" ]]; then
      line="$line early_reason=\"$early_abort_event\""
    fi
    render_line "$(colorize_line "$status" "$line")"
    last_sig="$sig"
  fi

  if [[ "$early_abort" == "1" ]] && [[ "$ONCE" != "1" ]] && [[ "$early_abort_reason" != "$last_early_abort_reason" ]]; then
    render_line "$(colorize_line running "EARLY_ABORT ts=$ts $early_abort_reason")"
    last_early_abort_reason="$early_abort_reason"
  fi

  if [[ "$done_flag" == "1" ]]; then
    done_state="ok"
    done_rc=0
    if [[ "$fail_flag" == "1" ]]; then
      done_state="fail"
      done_rc=1
    fi
    final_line="FLEET_FOLLOW_DONE ts=$ts status=$done_state total=$total done_ok=$done_ok done_fail=$done_fail orphaned=$orphaned"
    render_line "$(colorize_line "$done_state" "$final_line")"
    exit "$done_rc"
  fi

  if [[ "$ONCE" == "1" ]]; then
    exit 0
  fi
  sleep "$tick_sec"
done
