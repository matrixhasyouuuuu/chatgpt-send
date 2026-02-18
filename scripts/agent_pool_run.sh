#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT_DIR/bin/spawn_second_agent"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"
CHAT_POOL_MANAGER="$ROOT_DIR/scripts/chat_pool_manager.sh"

PROJECT_PATH=""
TASKS_FILE=""
CHAT_POOL_FILE=""
MODE="${POOL_MODE:-mock}"              # mock|live
CONCURRENCY="${POOL_CONCURRENCY:-3}"
ITERATIONS="${POOL_ITERATIONS:-1}"
TIMEOUT_SEC="${POOL_TIMEOUT_SEC:-900}"
FAIL_FAST_AFTER="${POOL_FAIL_FAST_AFTER:-0}"   # 0 = disabled
RETRY_MAX="${POOL_RETRY_MAX:-1}"               # retries for failed tasks
LAUNCHER="${POOL_LAUNCHER:-direct}"
BROWSER_POLICY="${POOL_BROWSER_POLICY:-required}"  # required|optional|disabled
OPEN_BROWSER="${POOL_OPEN_BROWSER:-1}"
INIT_SPECIALIST_CHAT="${POOL_INIT_SPECIALIST_CHAT:-0}"
CODEX_BIN="${POOL_CODEX_BIN:-codex}"
LOG_DIR=""
CHATGPT_SEND_PATH="${POOL_CHATGPT_SEND_PATH:-$CHATGPT_SEND_BIN}"
SKIP_GIT_REPO_CHECK=1
CHAT_POOL_CHECK="${POOL_CHAT_POOL_CHECK:-1}"                # 1|0
CHAT_POOL_PROBE="${POOL_CHAT_POOL_PROBE:-0}"                # 1|0
CHAT_POOL_PROBE_NO_SEND="${POOL_CHAT_POOL_PROBE_NO_SEND:-1}" # 1|0
FLEET_MONITOR_SCRIPT="${POOL_FLEET_MONITOR_SCRIPT:-$ROOT_DIR/scripts/child_fleet_monitor.sh}"
FLEET_MONITOR_ENABLED="${POOL_FLEET_MONITOR_ENABLED:-1}"     # 1|0
FLEET_MONITOR_POLL_SEC="${POOL_FLEET_MONITOR_POLL_SEC:-2}"
FLEET_MONITOR_HEARTBEAT_SEC="${POOL_FLEET_MONITOR_HEARTBEAT_SEC:-20}"
FLEET_MONITOR_TIMEOUT_SEC="${POOL_FLEET_MONITOR_TIMEOUT_SEC:-0}"
FLEET_MONITOR_STUCK_AFTER_SEC="${POOL_FLEET_MONITOR_STUCK_AFTER_SEC:-240}"
FLEET_MONITOR_STDOUT="${POOL_FLEET_MONITOR_STDOUT:-0}"       # 1|0
FLEET_WATCHDOG_ENABLED="${POOL_FLEET_WATCHDOG_ENABLED:-1}"   # 1|0
FLEET_WATCHDOG_COOLDOWN_SEC="${POOL_FLEET_WATCHDOG_COOLDOWN_SEC:-2}"
FLEET_GATE_ENABLED="${POOL_FLEET_GATE_ENABLED:-1}"           # 1|0
FLEET_GATE_TIMEOUT_SEC="${POOL_FLEET_GATE_TIMEOUT_SEC:-20}"
FLEET_GATE_HEARTBEAT_SEC="${POOL_FLEET_GATE_HEARTBEAT_SEC:-0}"
FLEET_REGISTRY_LOCK_TIMEOUT_SEC="${POOL_FLEET_REGISTRY_LOCK_TIMEOUT_SEC:-2}"
FLEET_ROSTER_LOCK_TIMEOUT_SEC="${POOL_FLEET_ROSTER_LOCK_TIMEOUT_SEC:-2}"
POOL_LOCK_FILE="${POOL_LOCK_FILE:-/tmp/chatgpt-send-agent-pool.lock}"
POOL_LOCK_TIMEOUT_SEC="${POOL_LOCK_TIMEOUT_SEC:-0}"
POOL_KILL_GRACE_SEC="${POOL_KILL_GRACE_SEC:-5}"
POOL_RUNS_ROOT="${POOL_RUNS_ROOT:-$ROOT_DIR/state/runs}"
POOL_GC="${POOL_GC:-auto}" # 0|1|auto
POOL_GC_KEEP_LAST="${POOL_GC_KEEP_LAST:-20}"
POOL_GC_KEEP_HOURS="${POOL_GC_KEEP_HOURS:-72}"
POOL_GC_MAX_TOTAL_MB="${POOL_GC_MAX_TOTAL_MB:-2048}"
POOL_GC_FREE_WARN_PCT="${POOL_GC_FREE_WARN_PCT:-10}"
POOL_GC_SCRIPT="${POOL_GC_SCRIPT:-$ROOT_DIR/scripts/fleet_gc.sh}"
POOL_STRICT_CHAT_PROOF="${POOL_STRICT_CHAT_PROOF:-auto}" # 0|1|auto
POOL_WRITE_REPORT="${POOL_WRITE_REPORT:-1}" # 0|1
POOL_REPORT_SCRIPT="${POOL_REPORT_SCRIPT:-$ROOT_DIR/scripts/pool_report.sh}"
POOL_REPORT_MD="${POOL_REPORT_MD:-}"
POOL_REPORT_JSON="${POOL_REPORT_JSON:-}"
POOL_REPORT_MAX_LAST_LINES="${POOL_REPORT_MAX_LAST_LINES:-80}"
POOL_REPORT_INCLUDE_LOGS="${POOL_REPORT_INCLUDE_LOGS:-0}" # 0|1

usage() {
  cat <<'USAGE'
Usage:
  scripts/agent_pool_run.sh --project-path PATH --tasks-file FILE [options]

Required:
  --project-path PATH
  --tasks-file FILE                one task per line; empty lines and # comments ignored

Options:
  --chat-pool-file FILE            one chat URL per line (https://chatgpt.com/c/<id>)
  --chat-pool-check / --no-chat-pool-check
  --chat-pool-probe / --no-chat-pool-probe
  --chat-pool-probe-no-send / --chat-pool-probe-send
  --mode MODE                      mock|live (default: mock)
  --concurrency N                  parallel launches (default: 3)
  --iterations N                   per-agent iterations hint (default: 1)
  --timeout-sec N                  per-agent timeout for spawn --wait (default: 900)
  --fail-fast-after N              stop launching new agents after N failures (0 disables)
  --retry-max N                    retries per failed task (default: 1)
  --launcher MODE                  auto|window|direct (default: direct)
  --browser-policy MODE            required|optional|disabled (default: required)
  --open-browser / --no-open-browser
  --init-specialist-chat / --no-init-specialist-chat
  --codex-bin PATH                 (default: codex)
  --chatgpt-send-path PATH         (default: bin/chatgpt_send)
  --log-dir PATH                   pool run dir (default: state/runs/pool-<ts>-<rand>)
  --skip-git-repo-check / --no-skip-git-repo-check
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-path) PROJECT_PATH="${2:-}"; shift 2 ;;
    --tasks-file) TASKS_FILE="${2:-}"; shift 2 ;;
    --chat-pool-file) CHAT_POOL_FILE="${2:-}"; shift 2 ;;
    --chat-pool-check) CHAT_POOL_CHECK=1; shift ;;
    --no-chat-pool-check) CHAT_POOL_CHECK=0; shift ;;
    --chat-pool-probe) CHAT_POOL_PROBE=1; shift ;;
    --no-chat-pool-probe) CHAT_POOL_PROBE=0; shift ;;
    --chat-pool-probe-no-send) CHAT_POOL_PROBE_NO_SEND=1; shift ;;
    --chat-pool-probe-send) CHAT_POOL_PROBE_NO_SEND=0; shift ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --iterations) ITERATIONS="${2:-}"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --fail-fast-after) FAIL_FAST_AFTER="${2:-}"; shift 2 ;;
    --retry-max) RETRY_MAX="${2:-}"; shift 2 ;;
    --launcher) LAUNCHER="${2:-}"; shift 2 ;;
    --browser-policy) BROWSER_POLICY="${2:-}"; shift 2 ;;
    --open-browser) OPEN_BROWSER=1; shift ;;
    --no-open-browser) OPEN_BROWSER=0; shift ;;
    --init-specialist-chat) INIT_SPECIALIST_CHAT=1; shift ;;
    --no-init-specialist-chat) INIT_SPECIALIST_CHAT=0; shift ;;
    --codex-bin) CODEX_BIN="${2:-}"; shift 2 ;;
    --chatgpt-send-path) CHATGPT_SEND_PATH="${2:-}"; shift 2 ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    --skip-git-repo-check) SKIP_GIT_REPO_CHECK=1; shift ;;
    --no-skip-git-repo-check) SKIP_GIT_REPO_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PROJECT_PATH" || -z "$TASKS_FILE" ]]; then
  usage >&2
  exit 2
fi
if [[ ! -x "$SPAWN" ]]; then
  echo "spawn_second_agent not found: $SPAWN" >&2
  exit 3
fi
if [[ ! -f "$TASKS_FILE" ]]; then
  echo "tasks file not found: $TASKS_FILE" >&2
  exit 4
fi
if [[ ! "$MODE" =~ ^(mock|live)$ ]]; then
  echo "invalid --mode: $MODE" >&2
  exit 5
fi
if [[ ! "$BROWSER_POLICY" =~ ^(required|optional|disabled)$ ]]; then
  echo "invalid --browser-policy: $BROWSER_POLICY" >&2
  exit 6
fi
if [[ ! "$POOL_GC" =~ ^(0|1|auto)$ ]]; then
  echo "invalid POOL_GC: $POOL_GC (expected 0|1|auto)" >&2
  exit 6
fi
if [[ ! "$POOL_STRICT_CHAT_PROOF" =~ ^(0|1|auto)$ ]]; then
  echo "invalid POOL_STRICT_CHAT_PROOF: $POOL_STRICT_CHAT_PROOF (expected 0|1|auto)" >&2
  exit 6
fi
for n in \
  "$CONCURRENCY" "$ITERATIONS" "$TIMEOUT_SEC" "$FAIL_FAST_AFTER" "$RETRY_MAX" \
  "$FLEET_MONITOR_POLL_SEC" "$FLEET_MONITOR_HEARTBEAT_SEC" "$FLEET_MONITOR_TIMEOUT_SEC" \
  "$FLEET_MONITOR_STUCK_AFTER_SEC" "$FLEET_WATCHDOG_COOLDOWN_SEC" "$FLEET_GATE_TIMEOUT_SEC" \
  "$FLEET_GATE_HEARTBEAT_SEC" "$FLEET_REGISTRY_LOCK_TIMEOUT_SEC" "$FLEET_ROSTER_LOCK_TIMEOUT_SEC" \
  "$POOL_LOCK_TIMEOUT_SEC" "$POOL_KILL_GRACE_SEC" \
  "$POOL_GC_KEEP_LAST" "$POOL_GC_KEEP_HOURS" "$POOL_GC_MAX_TOTAL_MB" "$POOL_GC_FREE_WARN_PCT" \
  "$POOL_REPORT_MAX_LAST_LINES"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "numeric option expected, got: $n" >&2
    exit 7
  fi
done
if [[ ! "$CHAT_POOL_CHECK" =~ ^[01]$ ]] || [[ ! "$CHAT_POOL_PROBE" =~ ^[01]$ ]] || [[ ! "$CHAT_POOL_PROBE_NO_SEND" =~ ^[01]$ ]] \
  || [[ ! "$FLEET_MONITOR_ENABLED" =~ ^[01]$ ]] || [[ ! "$FLEET_MONITOR_STDOUT" =~ ^[01]$ ]] \
  || [[ ! "$FLEET_WATCHDOG_ENABLED" =~ ^[01]$ ]] || [[ ! "$FLEET_GATE_ENABLED" =~ ^[01]$ ]] \
  || [[ ! "$POOL_WRITE_REPORT" =~ ^[01]$ ]] || [[ ! "$POOL_REPORT_INCLUDE_LOGS" =~ ^[01]$ ]]; then
  echo "switches must be 0 or 1" >&2
  exit 7
fi
if (( CONCURRENCY < 1 )); then
  echo "--concurrency must be >= 1" >&2
  exit 8
fi
if (( FLEET_MONITOR_ENABLED == 1 )) && [[ ! -x "$FLEET_MONITOR_SCRIPT" ]]; then
  echo "fleet monitor script not executable: $FLEET_MONITOR_SCRIPT" >&2
  exit 18
fi
if [[ "$POOL_GC" != "0" ]] && [[ ! -x "$POOL_GC_SCRIPT" ]]; then
  echo "pool gc script not executable: $POOL_GC_SCRIPT" >&2
  exit 18
fi
if [[ "$POOL_WRITE_REPORT" == "1" ]] && [[ ! -x "$POOL_REPORT_SCRIPT" ]]; then
  echo "pool report script not executable: $POOL_REPORT_SCRIPT" >&2
  exit 18
fi
if (( FLEET_MONITOR_POLL_SEC < 1 )); then
  echo "POOL_FLEET_MONITOR_POLL_SEC must be >= 1" >&2
  exit 19
fi
if (( FLEET_MONITOR_STUCK_AFTER_SEC < 1 )); then
  echo "POOL_FLEET_MONITOR_STUCK_AFTER_SEC must be >= 1" >&2
  exit 20
fi
if (( FLEET_GATE_ENABLED == 1 )) && (( FLEET_GATE_TIMEOUT_SEC < 1 )); then
  echo "POOL_FLEET_GATE_TIMEOUT_SEC must be >= 1 when gate is enabled" >&2
  exit 21
fi
if (( POOL_KILL_GRACE_SEC < 1 )); then
  echo "POOL_KILL_GRACE_SEC must be >= 1" >&2
  exit 22
fi
if (( POOL_GC_FREE_WARN_PCT > 100 )); then
  echo "POOL_GC_FREE_WARN_PCT must be <= 100" >&2
  exit 23
fi

mapfile -t TASKS < <(sed -e 's/\r$//' "$TASKS_FILE" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
if (( ${#TASKS[@]} == 0 )); then
  echo "no tasks in $TASKS_FILE" >&2
  exit 9
fi
TOTAL_AGENTS=${#TASKS[@]}
if (( CONCURRENCY > TOTAL_AGENTS )); then
  CONCURRENCY=$TOTAL_AGENTS
fi

declare -a CHAT_POOL=()
if [[ -n "$CHAT_POOL_FILE" ]]; then
  if [[ ! -f "$CHAT_POOL_FILE" ]]; then
    echo "chat pool file not found: $CHAT_POOL_FILE" >&2
    exit 10
  fi
  mapfile -t CHAT_POOL < <(sed -e 's/\r$//' "$CHAT_POOL_FILE" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
fi

if [[ "$MODE" == "live" ]] && (( CONCURRENCY > 1 )) && (( ${#CHAT_POOL[@]} == 0 )); then
  echo "live mode with concurrency>1 requires --chat-pool-file" >&2
  exit 11
fi
if (( ${#CHAT_POOL[@]} > 0 )) && (( ${#CHAT_POOL[@]} < TOTAL_AGENTS )); then
  echo "chat pool has fewer entries (${#CHAT_POOL[@]}) than tasks ($TOTAL_AGENTS)" >&2
  exit 12
fi
if (( ${#CHAT_POOL[@]} > 0 )); then
  unique_chat_count="$(printf '%s\n' "${CHAT_POOL[@]}" | sort -u | wc -l | tr -d '[:space:]')"
  if (( unique_chat_count < TOTAL_AGENTS )); then
    echo "chat pool must contain unique chat URLs per task" >&2
    exit 13
  fi
  for chat_url in "${CHAT_POOL[@]}"; do
    if [[ ! "$chat_url" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
      echo "invalid chat URL in pool: $chat_url" >&2
      exit 14
    fi
  done
fi

if (( ${#CHAT_POOL[@]} > 0 )) && [[ "$CHAT_POOL_CHECK" == "1" ]]; then
  if [[ ! -x "$CHAT_POOL_MANAGER" ]]; then
    echo "chat pool manager not executable: $CHAT_POOL_MANAGER" >&2
    exit 15
  fi
  check_out="$("$CHAT_POOL_MANAGER" check --file "$CHAT_POOL_FILE" --size "$TOTAL_AGENTS" 2>&1)" || {
    echo "$check_out" >&2
    exit 15
  }
  echo "$check_out"
fi

if (( ${#CHAT_POOL[@]} > 0 )) && [[ "$CHAT_POOL_PROBE" == "1" ]]; then
  if [[ ! -x "$CHAT_POOL_MANAGER" ]]; then
    echo "chat pool manager not executable: $CHAT_POOL_MANAGER" >&2
    exit 16
  fi
  probe_args=(probe --file "$CHAT_POOL_FILE" --transport "$MODE" --chatgpt-send-path "$CHATGPT_SEND_PATH")
  if [[ "$CHAT_POOL_PROBE_NO_SEND" == "1" ]]; then
    probe_args+=(--no-send)
  fi
  probe_out="$("$CHAT_POOL_MANAGER" "${probe_args[@]}" 2>&1)" || {
    echo "$probe_out" >&2
    exit 16
  }
  echo "$probe_out"
fi

if [[ "$POOL_RUNS_ROOT" != /* ]]; then
  POOL_RUNS_ROOT="$ROOT_DIR/$POOL_RUNS_ROOT"
fi

if [[ -z "$LOG_DIR" ]]; then
  POOL_RUN_ID="pool-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  mkdir -p "$POOL_RUNS_ROOT"
  LOG_DIR="$POOL_RUNS_ROOT/$POOL_RUN_ID"
else
  POOL_RUN_ID="$(basename "$LOG_DIR")"
fi

POOL_RUN_DIR="$LOG_DIR"
POOL_ACTIVE_MARKER="$POOL_RUN_DIR/.pool.active"
POOL_AGENT_DIR="$POOL_RUN_DIR/agents"
POOL_TASK_DIR="$POOL_RUN_DIR/tasks"
POOL_RESULT_DIR="$POOL_RUN_DIR/results"
mkdir -p "$POOL_AGENT_DIR" "$POOL_TASK_DIR" "$POOL_RESULT_DIR"
touch "$POOL_ACTIVE_MARKER"

SUMMARY_JSONL="$POOL_RUN_DIR/summary.jsonl"
SUMMARY_CSV="$POOL_RUN_DIR/summary.csv"
FINAL_SUMMARY_JSONL="$POOL_RUN_DIR/summary.final.jsonl"
FINAL_SUMMARY_CSV="$POOL_RUN_DIR/summary.final.csv"
FLEET_REGISTRY_FILE="$POOL_RUN_DIR/fleet_registry.jsonl"
FLEET_ROSTER_JSONL="$POOL_RUN_DIR/fleet_roster.jsonl"
FLEET_MONITOR_PID_FILE="$POOL_RUN_DIR/fleet.monitor.pid"
FLEET_MONITOR_LOG="$POOL_RUN_DIR/fleet.monitor.log"
FLEET_SUMMARY_JSON="$POOL_RUN_DIR/fleet.summary.json"
FLEET_SUMMARY_CSV="$POOL_RUN_DIR/fleet.summary.csv"
FLEET_HEARTBEAT_FILE="$POOL_RUN_DIR/fleet.heartbeat"
FLEET_EVENTS_JSONL="$POOL_RUN_DIR/fleet.events.jsonl"
FLEET_EVENTS_LOCK_FILE="$POOL_RUN_DIR/fleet.events.lock"
FLEET_GATE_LOG="$POOL_RUN_DIR/fleet.gate.log"
POOL_WATCHDOG_LOG="$POOL_RUN_DIR/pool.watchdog.log"
POOL_GC_LOG="$POOL_RUN_DIR/pool.gc.log"
printf 'agent,attempt,spawn_rc,child_run_id,status,exit_code,browser_used,duration_sec,chat_url,assigned_chat_url,observed_chat_url_before,observed_chat_url_after,chat_match,fail_kind,fail_reason,task_hash,task_nonce,result_json,stdout_file,task_file\n' >"$SUMMARY_CSV"
: >"$SUMMARY_JSONL"
: >"$FLEET_REGISTRY_FILE"
: >"$FLEET_ROSTER_JSONL"
: >"$POOL_WATCHDOG_LOG"

declare -A TASK_FILE_BY_AGENT=()
declare -A CHAT_BY_AGENT=()
for ((i=1; i<=TOTAL_AGENTS; i++)); do
  task="${TASKS[$((i-1))]}"
  task_file="$POOL_TASK_DIR/agent_${i}.task.txt"
  printf '%s\n' "$task" >"$task_file"
  TASK_FILE_BY_AGENT["$i"]="$task_file"
  if (( ${#CHAT_POOL[@]} > 0 )); then
    CHAT_BY_AGENT["$i"]="${CHAT_POOL[$((i-1))]}"
  else
    CHAT_BY_AGENT["$i"]=""
  fi
done

browser_flag=("--browser-optional")
case "$BROWSER_POLICY" in
  required) browser_flag=("--browser-required") ;;
  optional) browser_flag=("--browser-optional") ;;
  disabled) browser_flag=("--browser-disabled") ;;
esac

open_browser_flag=("--open-browser")
if [[ "$OPEN_BROWSER" == "0" ]] || [[ "$BROWSER_POLICY" == "disabled" ]]; then
  open_browser_flag=("--no-open-browser")
fi

init_specialist_flag=("--no-init-specialist-chat")
if [[ "$INIT_SPECIALIST_CHAT" == "1" ]]; then
  init_specialist_flag=("--init-specialist-chat")
fi

skip_git_flag=("--skip-git-repo-check")
if [[ "$SKIP_GIT_REPO_CHECK" == "0" ]]; then
  skip_git_flag=("--no-skip-git-repo-check")
fi

declare -A FINAL_RC=()
declare -A FINAL_OUT=()
declare -A FINAL_ATTEMPT=()
declare -a ACTIVE_SPAWN_PIDS=()
FLEET_WATCHDOG_RESTARTS=0
FLEET_WATCHDOG_LAST_RESTART_EPOCH=0
FLEET_GATE_STATUS="SKIPPED"
FLEET_GATE_REASON="disabled"
FLEET_GATE_RC=0
FLEET_GATE_COUNTS_JSON="{}"
FLEET_GATE_DISK_STATUS="unknown"
FLEET_GATE_EXPECTED_TOTAL=0
FLEET_GATE_OBSERVED_TOTAL=0
FLEET_GATE_COMPLETED_TOTAL=0
FLEET_GATE_MISSING_ARTIFACTS_TOTAL=0
FLEET_CHAT_OK_TOTAL=0
FLEET_CHAT_MISMATCH_TOTAL=0
FLEET_CHAT_UNKNOWN_TOTAL=0
POOL_STRICT_CHAT_PROOF_EFFECTIVE=0
POOL_LOCK_FD=""
POOL_ABORT=0
POOL_ABORT_SIGNAL=""
POOL_ABORT_RC=0
POOL_ABORT_HANDLING=0
POOL_ABORT_KILLED=0
POOL_ABORT_REMAINING=0
POOL_GC_APPLIED=0
POOL_GC_REASON="disabled"
POOL_GC_EXIT_CODE=0

watchdog_log() {
  local msg="$1"
  printf '[pool-watchdog] ts=%s run_id=%s %s\n' "$(date -Iseconds)" "$POOL_RUN_ID" "$msg" >>"$POOL_WATCHDOG_LOG"
}

remove_pool_active_marker() {
  rm -f "$POOL_ACTIVE_MARKER" >/dev/null 2>&1 || true
}

disk_free_pct_at_path() {
  local path="$1"
  local used=""
  used="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}' | head -n 1)"
  if [[ ! "$used" =~ ^[0-9]+$ ]]; then
    printf '0'
    return 0
  fi
  local free=$((100 - used))
  if (( free < 0 )); then
    free=0
  fi
  printf '%s' "$free"
}

run_pool_gc_if_needed() {
  POOL_GC_APPLIED=0
  POOL_GC_REASON="disabled"
  POOL_GC_EXIT_CODE=0
  : >"$POOL_GC_LOG"

  local should_run=0
  if [[ "$POOL_GC" == "1" ]]; then
    should_run=1
    POOL_GC_REASON="forced"
  elif [[ "$POOL_GC" == "auto" ]]; then
    local free_pct
    free_pct="$(disk_free_pct_at_path "$POOL_RUNS_ROOT")"
    if [[ "$free_pct" =~ ^[0-9]+$ ]] && (( free_pct <= POOL_GC_FREE_WARN_PCT )); then
      should_run=1
      POOL_GC_REASON="auto_low_disk"
    else
      POOL_GC_REASON="auto_skip"
      watchdog_log "event=pool_gc_skip mode=auto free_pct=${free_pct} warn_pct=${POOL_GC_FREE_WARN_PCT}"
      return 0
    fi
  else
    POOL_GC_REASON="disabled"
    return 0
  fi

  if (( should_run == 0 )); then
    return 0
  fi

  watchdog_log "event=pool_gc_start reason=${POOL_GC_REASON} root=${POOL_RUNS_ROOT}"
  set +e
  "$POOL_GC_SCRIPT" \
    --root "$POOL_RUNS_ROOT" \
    --keep-last "$POOL_GC_KEEP_LAST" \
    --keep-hours "$POOL_GC_KEEP_HOURS" \
    --max-total-mb "$POOL_GC_MAX_TOTAL_MB" >"$POOL_GC_LOG" 2>&1
  POOL_GC_EXIT_CODE=$?
  set -e
  if [[ "$POOL_GC_EXIT_CODE" == "0" ]]; then
    POOL_GC_APPLIED=1
    watchdog_log "event=pool_gc_done reason=${POOL_GC_REASON} log=${POOL_GC_LOG}"
  else
    POOL_GC_APPLIED=0
    watchdog_log "event=pool_gc_failed reason=${POOL_GC_REASON} rc=${POOL_GC_EXIT_CODE} log=${POOL_GC_LOG}"
  fi
}

read_pid_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    tr -d '[:space:]' <"$path" 2>/dev/null || true
  fi
}

pid_is_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

acquire_pool_lock() {
  mkdir -p "$(dirname "$POOL_LOCK_FILE")"
  exec {POOL_LOCK_FD}>"$POOL_LOCK_FILE"
  if [[ "$POOL_LOCK_TIMEOUT_SEC" == "0" ]]; then
    if ! flock -n "$POOL_LOCK_FD"; then
      echo "E_POOL_ALREADY_RUNNING lock_file=${POOL_LOCK_FILE} timeout_sec=${POOL_LOCK_TIMEOUT_SEC}" >&2
      exit 2
    fi
  else
    if ! flock -w "$POOL_LOCK_TIMEOUT_SEC" "$POOL_LOCK_FD"; then
      echo "E_POOL_ALREADY_RUNNING lock_file=${POOL_LOCK_FILE} timeout_sec=${POOL_LOCK_TIMEOUT_SEC}" >&2
      exit 2
    fi
  fi
}

release_pool_lock() {
  if [[ -n "${POOL_LOCK_FD:-}" ]]; then
    exec {POOL_LOCK_FD}>&- || true
    POOL_LOCK_FD=""
  fi
}

track_active_spawn_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  ACTIVE_SPAWN_PIDS+=("$pid")
}

untrack_active_spawn_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  local -a keep=()
  local item=""
  for item in "${ACTIVE_SPAWN_PIDS[@]:-}"; do
    if [[ "$item" != "$pid" ]]; then
      keep+=("$item")
    fi
  done
  ACTIVE_SPAWN_PIDS=("${keep[@]}")
}

terminate_pids_with_grace() {
  local grace_sec="$1"
  shift
  local -a pids=("$@")
  local -a alive=()
  local pid=""
  for pid in "${pids[@]}"; do
    if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) && (( pid != $$ )) && kill -0 "$pid" >/dev/null 2>&1; then
      alive+=("$pid")
    fi
  done
  if (( ${#alive[@]} == 0 )); then
    return 0
  fi
  POOL_ABORT_KILLED=$((POOL_ABORT_KILLED + ${#alive[@]}))
  kill -TERM "${alive[@]}" >/dev/null 2>&1 || true
  sleep "$grace_sec"
  local -a still_alive=()
  for pid in "${alive[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      still_alive+=("$pid")
    fi
  done
  if (( ${#still_alive[@]} > 0 )); then
    POOL_ABORT_REMAINING=$((POOL_ABORT_REMAINING + ${#still_alive[@]}))
    kill -KILL "${still_alive[@]}" >/dev/null 2>&1 || true
  fi
}

collect_registry_child_pids() {
  if [[ ! -f "$FLEET_REGISTRY_FILE" ]]; then
    return 0
  fi
  python3 - "$FLEET_REGISTRY_FILE" <<'PY'
import json
import pathlib
import sys

registry = pathlib.Path(sys.argv[1])
seen = set()
for raw in registry.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    pid_file = str(obj.get("pid_file", "")).strip()
    if not pid_file:
        continue
    p = pathlib.Path(pid_file)
    if not p.exists():
        continue
    try:
        pid = p.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        continue
    if pid.isdigit() and pid not in seen:
        seen.add(pid)
        print(pid)
PY
}

terminate_active_children() {
  local -a child_pids=()
  if mapfile -t child_pids < <(collect_registry_child_pids); then
    terminate_pids_with_grace "$POOL_KILL_GRACE_SEC" "${child_pids[@]}"
  fi
}

terminate_active_spawns() {
  terminate_pids_with_grace "$POOL_KILL_GRACE_SEC" "${ACTIVE_SPAWN_PIDS[@]:-}"
}

on_pool_signal() {
  local sig="$1"
  if (( POOL_ABORT_HANDLING == 1 )); then
    return 0
  fi
  POOL_ABORT_HANDLING=1
  POOL_ABORT=1
  POOL_ABORT_SIGNAL="$sig"
  if [[ "$sig" == "INT" ]]; then
    POOL_ABORT_RC=130
  else
    POOL_ABORT_RC=143
  fi
  watchdog_log "event=pool_abort_start signal=${sig}"
  terminate_active_spawns
  terminate_active_children
  echo "POOL_ABORT signal=${sig} killed=${POOL_ABORT_KILLED} remaining=${POOL_ABORT_REMAINING}" >&2
  watchdog_log "event=pool_abort_done signal=${sig}"
  POOL_ABORT_HANDLING=0
}

trap 'on_pool_signal INT' INT
trap 'on_pool_signal TERM' TERM
trap 'remove_pool_active_marker; release_pool_lock' EXIT

start_fleet_monitor() {
  local reason="${1:-manual}"
  if [[ "$FLEET_MONITOR_ENABLED" != "1" ]]; then
    return 0
  fi

  local existing_pid
  existing_pid="$(read_pid_file "$FLEET_MONITOR_PID_FILE")"
  if pid_is_alive "$existing_pid"; then
    return 0
  fi
  rm -f "$FLEET_MONITOR_PID_FILE" >/dev/null 2>&1 || true
  local cmd=(
    "$FLEET_MONITOR_SCRIPT"
    --pool-run-dir "$POOL_RUN_DIR"
    --poll-sec "$FLEET_MONITOR_POLL_SEC"
    --heartbeat-sec "$FLEET_MONITOR_HEARTBEAT_SEC"
    --timeout-sec "$FLEET_MONITOR_TIMEOUT_SEC"
    --stuck-after-sec "$FLEET_MONITOR_STUCK_AFTER_SEC"
    --pid-file "$FLEET_MONITOR_PID_FILE"
    --monitor-log "$FLEET_MONITOR_LOG"
    --summary-json "$FLEET_SUMMARY_JSON"
    --summary-csv "$FLEET_SUMMARY_CSV"
    --registry-file "$FLEET_REGISTRY_FILE"
    --roster-jsonl "$FLEET_ROSTER_JSONL"
  )
  if [[ "$FLEET_MONITOR_STDOUT" == "1" ]]; then
    cmd+=(--stdout)
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid -f "${cmd[@]}" >/dev/null 2>&1 < /dev/null || true
  else
    nohup "${cmd[@]}" >/dev/null 2>&1 &
  fi

  local monitor_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    monitor_pid="$(read_pid_file "$FLEET_MONITOR_PID_FILE")"
    if pid_is_alive "$monitor_pid"; then
      watchdog_log "event=fleet_monitor_started pid=${monitor_pid} reason=${reason}"
      return 0
    fi
    sleep 0.1
  done
  watchdog_log "event=fleet_monitor_start_failed reason=${reason}"
  return 1
}

stop_fleet_monitor_if_running() {
  if [[ "$FLEET_MONITOR_ENABLED" != "1" ]]; then
    return 0
  fi
  local monitor_pid
  monitor_pid="$(read_pid_file "$FLEET_MONITOR_PID_FILE")"
  if ! pid_is_alive "$monitor_pid"; then
    return 0
  fi
  kill "$monitor_pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pid_is_alive "$monitor_pid"; then
      break
    fi
    sleep 0.2
  done
  if pid_is_alive "$monitor_pid"; then
    kill -9 "$monitor_pid" >/dev/null 2>&1 || true
  fi
  watchdog_log "event=fleet_monitor_stopped pid=${monitor_pid}"
}

ensure_fleet_monitor_alive() {
  local context="${1:-runtime}"
  if [[ "$FLEET_MONITOR_ENABLED" != "1" ]] || [[ "$FLEET_WATCHDOG_ENABLED" != "1" ]]; then
    return 0
  fi
  local monitor_pid
  monitor_pid="$(read_pid_file "$FLEET_MONITOR_PID_FILE")"
  if pid_is_alive "$monitor_pid"; then
    return 0
  fi
  local now_epoch
  now_epoch="$(date +%s)"
  if (( FLEET_WATCHDOG_COOLDOWN_SEC > 0 )) && (( now_epoch - FLEET_WATCHDOG_LAST_RESTART_EPOCH < FLEET_WATCHDOG_COOLDOWN_SEC )); then
    return 0
  fi
  FLEET_WATCHDOG_LAST_RESTART_EPOCH="$now_epoch"
  if start_fleet_monitor "watchdog_${context}"; then
    FLEET_WATCHDOG_RESTARTS=$((FLEET_WATCHDOG_RESTARTS + 1))
    watchdog_log "event=fleet_monitor_restarted count=${FLEET_WATCHDOG_RESTARTS} context=${context}"
  else
    watchdog_log "event=fleet_monitor_restart_failed context=${context}"
  fi
}

run_fleet_gate() {
  FLEET_GATE_STATUS="SKIPPED"
  FLEET_GATE_REASON="disabled"
  FLEET_GATE_RC=0
  FLEET_GATE_COUNTS_JSON="{}"
  FLEET_GATE_DISK_STATUS="unknown"
  FLEET_GATE_EXPECTED_TOTAL="$TOTAL_AGENTS"
  FLEET_GATE_OBSERVED_TOTAL=0
  FLEET_GATE_COMPLETED_TOTAL=0
  FLEET_GATE_MISSING_ARTIFACTS_TOTAL=0
  FLEET_CHAT_OK_TOTAL=0
  FLEET_CHAT_MISMATCH_TOTAL=0
  FLEET_CHAT_UNKNOWN_TOTAL=0
  if [[ "$POOL_STRICT_CHAT_PROOF" == "1" ]]; then
    POOL_STRICT_CHAT_PROOF_EFFECTIVE=1
  elif [[ "$POOL_STRICT_CHAT_PROOF" == "0" ]]; then
    POOL_STRICT_CHAT_PROOF_EFFECTIVE=0
  else
    if [[ "$MODE" == "live" ]] || [[ -n "$CHAT_POOL_FILE" ]]; then
      POOL_STRICT_CHAT_PROOF_EFFECTIVE=1
    else
      POOL_STRICT_CHAT_PROOF_EFFECTIVE=0
    fi
  fi

  if [[ "$FLEET_GATE_ENABLED" != "1" ]]; then
    stop_fleet_monitor_if_running
    return 0
  fi
  if [[ ! -x "$FLEET_MONITOR_SCRIPT" ]]; then
    FLEET_GATE_STATUS="FAIL"
    FLEET_GATE_REASON="fleet_monitor_missing"
    FLEET_GATE_RC=127
    return 1
  fi

  stop_fleet_monitor_if_running

  set +e
  "$FLEET_MONITOR_SCRIPT" \
    --pool-run-dir "$POOL_RUN_DIR" \
    --poll-sec 1 \
    --heartbeat-sec "$FLEET_GATE_HEARTBEAT_SEC" \
    --timeout-sec "$FLEET_GATE_TIMEOUT_SEC" \
    --stuck-after-sec "$FLEET_MONITOR_STUCK_AFTER_SEC" \
    --monitor-log "$FLEET_MONITOR_LOG" \
    --summary-json "$FLEET_SUMMARY_JSON" \
    --summary-csv "$FLEET_SUMMARY_CSV" \
    --registry-file "$FLEET_REGISTRY_FILE" \
    --roster-jsonl "$FLEET_ROSTER_JSONL" >"$FLEET_GATE_LOG" 2>&1
  FLEET_GATE_RC=$?
  set -e

  if [[ -s "$FLEET_SUMMARY_JSON" ]]; then
    if readarray -t gate_meta < <(python3 - "$FLEET_SUMMARY_JSON" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out = {
    "total": int(obj.get("total", 0)),
    "done_ok": int(obj.get("done_ok", 0)),
    "done_fail": int(obj.get("done_fail", 0)),
    "orphaned": int(obj.get("orphaned", 0)),
    "running": int(obj.get("running", 0)),
    "stuck": int(obj.get("stuck", 0)),
    "unknown": int(obj.get("unknown", 0)),
    "disk_status": str(obj.get("disk_status", "unknown") or "unknown"),
    "disk_free_pct": obj.get("disk_free_pct"),
    "disk_avail_kb": obj.get("disk_avail_kb"),
    "observed_total": int((obj.get("discovery_sources") or {}).get("merged", 0)),
    "merged_total": int((obj.get("discovery_sources") or {}).get("merged", 0)),
    "completed_total": int(obj.get("done_ok", 0)) + int(obj.get("done_fail", 0)) + int(obj.get("orphaned", 0)),
    "missing_artifacts_total": int(obj.get("missing_artifacts_total", 0)),
    "chat_ok_total": int(obj.get("chat_ok_total", 0)),
    "chat_mismatch_total": int(obj.get("chat_mismatch_total", 0)),
    "chat_unknown_total": int(obj.get("chat_unknown_total", 0)),
}
print(json.dumps(out, ensure_ascii=False, sort_keys=True))
print(out["disk_status"])
print(out["observed_total"])
print(out["completed_total"])
print(out["missing_artifacts_total"])
print(out["chat_ok_total"])
print(out["chat_mismatch_total"])
print(out["chat_unknown_total"])
PY
); then
      FLEET_GATE_COUNTS_JSON="${gate_meta[0]:-{}}"
      FLEET_GATE_DISK_STATUS="${gate_meta[1]:-unknown}"
      FLEET_GATE_OBSERVED_TOTAL="${gate_meta[2]:-0}"
      FLEET_GATE_COMPLETED_TOTAL="${gate_meta[3]:-0}"
      FLEET_GATE_MISSING_ARTIFACTS_TOTAL="${gate_meta[4]:-0}"
      FLEET_CHAT_OK_TOTAL="${gate_meta[5]:-0}"
      FLEET_CHAT_MISMATCH_TOTAL="${gate_meta[6]:-0}"
      FLEET_CHAT_UNKNOWN_TOTAL="${gate_meta[7]:-0}"
      if [[ -z "$FLEET_GATE_COUNTS_JSON" ]]; then
        FLEET_GATE_COUNTS_JSON="{}"
      fi
    else
      FLEET_GATE_COUNTS_JSON="{}"
      FLEET_GATE_DISK_STATUS="unknown"
      FLEET_GATE_OBSERVED_TOTAL=0
      FLEET_GATE_COMPLETED_TOTAL=0
      FLEET_GATE_MISSING_ARTIFACTS_TOTAL=0
      FLEET_CHAT_OK_TOTAL=0
      FLEET_CHAT_MISMATCH_TOTAL=0
      FLEET_CHAT_UNKNOWN_TOTAL=0
    fi
  fi

  if [[ "$FLEET_GATE_MISSING_ARTIFACTS_TOTAL" =~ ^[0-9]+$ ]] && (( FLEET_GATE_MISSING_ARTIFACTS_TOTAL > 0 )); then
    FLEET_GATE_STATUS="FAIL"
    FLEET_GATE_REASON="missing_artifacts"
    FLEET_GATE_RC=126
    return 1
  fi
  if [[ "$FLEET_GATE_OBSERVED_TOTAL" =~ ^[0-9]+$ ]] && (( FLEET_GATE_OBSERVED_TOTAL < FLEET_GATE_EXPECTED_TOTAL )); then
    FLEET_GATE_STATUS="FAIL"
    FLEET_GATE_REASON="fleet_incomplete"
    FLEET_GATE_RC=127
    return 1
  fi
  if [[ "$POOL_STRICT_CHAT_PROOF_EFFECTIVE" == "1" ]]; then
    if [[ "$FLEET_CHAT_MISMATCH_TOTAL" =~ ^[0-9]+$ ]] && (( FLEET_CHAT_MISMATCH_TOTAL > 0 )); then
      FLEET_GATE_STATUS="FAIL"
      FLEET_GATE_REASON="chat_mismatch"
      FLEET_GATE_RC=123
      return 1
    fi
    if [[ "$FLEET_CHAT_UNKNOWN_TOTAL" =~ ^[0-9]+$ ]] && (( FLEET_CHAT_UNKNOWN_TOTAL > 0 )); then
      FLEET_GATE_STATUS="FAIL"
      FLEET_GATE_REASON="chat_proof_unknown"
      FLEET_GATE_RC=122
      return 1
    fi
  fi
  if [[ "$FLEET_GATE_DISK_STATUS" == "fail" ]]; then
    FLEET_GATE_STATUS="FAIL"
    FLEET_GATE_REASON="disk_low"
    FLEET_GATE_RC=125
    return 1
  fi

  if [[ "$FLEET_GATE_RC" == "0" ]]; then
    FLEET_GATE_STATUS="PASS"
    FLEET_GATE_REASON="ok"
    return 0
  fi

  FLEET_GATE_STATUS="FAIL"
  case "$FLEET_GATE_RC" in
    1) FLEET_GATE_REASON="failed_or_orphaned" ;;
    73) FLEET_GATE_REASON="lock_busy" ;;
    124) FLEET_GATE_REASON="timeout" ;;
    *) FLEET_GATE_REASON="monitor_rc_${FLEET_GATE_RC}" ;;
  esac
  return 1
}

append_fleet_roster_row() {
  local agent_id="$1"
  local attempt="$2"
  local child_run_id="$3"
  local child_run_dir="$4"
  local child_result_json="$5"
  local out_file="$6"
  local assigned_chat_url="$7"
  if [[ -z "$child_run_id" ]] && [[ -z "$child_run_dir" ]]; then
    return 0
  fi

  local pid_file=""
  local status_file=""
  local log_file=""
  pid_file="$(sed -n 's/^PID_FILE=//p' "$out_file" | tail -n 1 || true)"
  status_file="$(sed -n 's/^STATUS_FILE=//p' "$out_file" | tail -n 1 || true)"
  log_file="$(sed -n 's/^LOG_FILE=//p' "$out_file" | tail -n 1 || true)"

  local payload=""
  payload="$(python3 - \
    "$agent_id" "$attempt" "$child_run_id" "$child_run_dir" "$child_result_json" \
    "$pid_file" "$status_file" "$log_file" "$assigned_chat_url" "$MODE" "$LAUNCHER" <<'PY'
import json
import sys
import time

(
    agent_id,
    attempt,
    run_id,
    run_dir,
    result_json,
    pid_file,
    status_file,
    log_file,
    assigned_chat_url,
    pool_mode,
    launcher,
) = sys.argv[1:12]

obj = {
    "ts_ms": int(time.time() * 1000),
    "agent_id": int(agent_id) if str(agent_id).isdigit() else agent_id,
    "attempt": int(attempt) if str(attempt).isdigit() else None,
    "run_id": run_id or "",
    "run_dir": run_dir or "",
    "result_json": result_json or "",
    "pid_file": pid_file or "",
    "status_file": status_file or "",
    "log_file": log_file or "",
    "assigned_chat_url": assigned_chat_url or "",
    "pool_mode": pool_mode or "",
    "launcher": launcher or "",
}
print(json.dumps(obj, ensure_ascii=False))
PY
)"
  if [[ -z "$payload" ]]; then
    return 0
  fi

  local roster_lock="${FLEET_ROSTER_JSONL}.lock"
  local roster_fd=""
  exec {roster_fd}>>"$roster_lock" || true
  if [[ -n "$roster_fd" ]]; then
    if ! flock -w "$FLEET_ROSTER_LOCK_TIMEOUT_SEC" "$roster_fd" >/dev/null 2>&1; then
      echo "W_FLEET_ROSTER_LOCK_TIMEOUT file=${FLEET_ROSTER_JSONL} timeout_sec=${FLEET_ROSTER_LOCK_TIMEOUT_SEC} run_id=${child_run_id}" >&2
      exec {roster_fd}>&- || true
      return 0
    fi
  fi
  printf '%s\n' "$payload" >>"$FLEET_ROSTER_JSONL"
  if [[ -n "$roster_fd" ]]; then
    exec {roster_fd}>&- || true
  fi
}

run_one_agent_attempt() {
  local agent_id="$1"
  local attempt="$2"
  local out_file="$3"
  local task_file="${TASK_FILE_BY_AGENT[$agent_id]}"
  local chat_url="${CHAT_BY_AGENT[$agent_id]}"
  local fleet_registry_file="$FLEET_REGISTRY_FILE"

  mkdir -p "$POOL_AGENT_DIR/agent_${agent_id}"
  local run_env=()
  if [[ "$MODE" == "live" ]]; then
    run_env+=("CHATGPT_SEND_TRANSPORT=cdp")
  else
    run_env+=("CHATGPT_SEND_TRANSPORT=mock")
  fi
  if [[ -n "$chat_url" ]]; then
    run_env+=("CHATGPT_SEND_FORCE_CHAT_URL=$chat_url")
  fi
  run_env+=("CHATGPT_SEND_FLEET_REGISTRY_FILE=$fleet_registry_file")
  run_env+=("CHATGPT_SEND_FLEET_REGISTRY_LOCK_TIMEOUT_SEC=$FLEET_REGISTRY_LOCK_TIMEOUT_SEC")
  run_env+=("CHATGPT_SEND_FLEET_AGENT_ID=$agent_id")
  run_env+=("CHATGPT_SEND_FLEET_ATTEMPT=$attempt")
  run_env+=("CHATGPT_SEND_FLEET_ASSIGNED_CHAT_URL=$chat_url")

  env "${run_env[@]}" \
    "$SPAWN" \
    --project-path "$PROJECT_PATH" \
    --task-file "$task_file" \
    --iterations "$ITERATIONS" \
    --launcher "$LAUNCHER" \
    --wait \
    --timeout-sec "$TIMEOUT_SEC" \
    --log-dir "$POOL_RESULT_DIR" \
    --codex-bin "$CODEX_BIN" \
    --chatgpt-send-path "$CHATGPT_SEND_PATH" \
    "${browser_flag[@]}" \
    "${open_browser_flag[@]}" \
    "${init_specialist_flag[@]}" \
    "${skip_git_flag[@]}" >"$out_file" 2>&1
}

append_summary_for_attempt() {
  local agent_id="$1"
  local attempt="$2"
  local spawn_rc="$3"
  local out_file="$4"
  local chat_url_assigned="${CHAT_BY_AGENT[$agent_id]}"
  local task_file="${TASK_FILE_BY_AGENT[$agent_id]}"

  local child_run_id=""
  local child_run_dir=""
  local child_result_json=""
  child_run_id="$(sed -n 's/^CHILD_RUN_ID=//p' "$out_file" | tail -n 1 || true)"
  child_run_dir="$(sed -n 's/^CHILD_RUN_DIR=//p' "$out_file" | tail -n 1 || true)"
  child_result_json="$(sed -n 's/^CHILD_RESULT_JSON=//p' "$out_file" | tail -n 1 || true)"
  append_fleet_roster_row "$agent_id" "$attempt" "$child_run_id" "$child_run_dir" "$child_result_json" "$out_file" "$chat_url_assigned"

  local status=""
  local exit_code=""
  local browser_used=""
  local duration_sec=""
  local observed_chat_url_before=""
  local observed_chat_url_after=""
  local task_hash=""
  local task_nonce=""
  local chat_match=""
  local fail_kind=""
  local fail_reason=""
  local transport_log=""
  if [[ -n "$child_result_json" ]] && [[ -f "$child_result_json" ]]; then
    readarray -t parsed < <(python3 - "$child_result_json" "$task_file" "$POOL_RUN_ID" "$agent_id" "$attempt" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
print(obj.get("status",""))
print(obj.get("exit_code",""))
print(str(obj.get("browser_used","")))
print(obj.get("duration_sec",""))
print(obj.get("pinned_route_url",""))
print(obj.get("specialist_chat_url",""))
task_data = open(sys.argv[2], encoding="utf-8", errors="replace").read()
import hashlib
task_hash = hashlib.sha256(task_data.encode("utf-8")).hexdigest()
print(task_hash)
print(f"{sys.argv[3]}-a{sys.argv[4]}-t{sys.argv[5]}-{task_hash[:12]}")
PY
)
    status="${parsed[0]:-}"
    exit_code="${parsed[1]:-}"
    browser_used="${parsed[2]:-}"
    duration_sec="${parsed[3]:-}"
    observed_chat_url_before="${parsed[4]:-}"
    observed_chat_url_after="${parsed[5]:-}"
    task_hash="${parsed[6]:-}"
    task_nonce="${parsed[7]:-}"
  fi

  if [[ -z "$task_hash" ]]; then
    readarray -t task_meta < <(python3 - "$task_file" "$POOL_RUN_ID" "$agent_id" "$attempt" <<'PY'
import hashlib, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
task_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
print(task_hash)
print(f"{sys.argv[2]}-a{sys.argv[3]}-t{sys.argv[4]}-{task_hash[:12]}")
PY
)
    task_hash="${task_meta[0]:-}"
    task_nonce="${task_meta[1]:-}"
  fi

  if [[ -n "$child_result_json" ]]; then
    transport_log="$(dirname "$child_result_json")/chatgpt_send/transport.log"
    if [[ -f "$transport_log" ]]; then
      readarray -t transport_urls < <(rg -N --only-matching -o "https://chatgpt\\.com/c/[A-Za-z0-9-]+" "$transport_log" || true)
      if (( ${#transport_urls[@]} > 0 )); then
        if [[ -z "$observed_chat_url_before" ]]; then
          observed_chat_url_before="${transport_urls[0]}"
        fi
        if [[ -z "$observed_chat_url_after" ]]; then
          observed_chat_url_after="${transport_urls[$((${#transport_urls[@]}-1))]}"
        fi
      fi
    fi
  fi

  if [[ -n "$chat_url_assigned" ]]; then
    if [[ -n "$observed_chat_url_after" ]]; then
      if [[ "$observed_chat_url_after" == "$chat_url_assigned" ]]; then
        chat_match="1"
      else
        chat_match="0"
      fi
    elif [[ -n "$observed_chat_url_before" ]]; then
      if [[ "$observed_chat_url_before" == "$chat_url_assigned" ]]; then
        chat_match="1"
      else
        chat_match="0"
      fi
    fi
  fi

  if [[ "$spawn_rc" == "99" ]]; then
    fail_kind="FAIL_FAST"
    fail_reason="fail_fast_threshold"
  elif [[ "$spawn_rc" != "0" ]]; then
    fail_kind="FAIL_AGENT_ERROR"
    fail_reason="spawn_rc_${spawn_rc}"
  elif [[ -n "$status" && "$status" != "OK" ]]; then
    fail_kind="FAIL_AGENT_ERROR"
    fail_reason="child_status_${status}"
  elif [[ -n "$chat_url_assigned" && "$chat_match" == "0" ]]; then
    fail_kind="FAIL_CHAT_MIXUP"
    fail_reason="assigned_chat_mismatch"
  elif [[ -n "$chat_url_assigned" && -z "$observed_chat_url_before" && -z "$observed_chat_url_after" ]]; then
    fail_kind="FAIL_CHAT_MIXUP"
    fail_reason="missing_observed_chat_url"
  else
    fail_kind="OK"
    fail_reason="ok"
  fi

  python3 - \
    "$agent_id" "$attempt" "$spawn_rc" "$child_run_id" "$status" "$exit_code" "$browser_used" "$duration_sec" \
    "$chat_url_assigned" "$observed_chat_url_before" "$observed_chat_url_after" "$chat_match" "$fail_kind" "$fail_reason" \
    "$task_hash" "$task_nonce" "$child_result_json" "$out_file" "$task_file" <<'PY' >>"$SUMMARY_JSONL"
import json, sys
print(json.dumps({
    "agent": int(sys.argv[1]),
    "attempt": int(sys.argv[2]),
    "spawn_rc": int(sys.argv[3]),
    "child_run_id": sys.argv[4],
    "status": sys.argv[5],
    "exit_code": sys.argv[6],
    "browser_used": sys.argv[7],
    "duration_sec": sys.argv[8],
    "chat_url": sys.argv[9],
    "assigned_chat_url": sys.argv[9],
    "observed_chat_url_before": sys.argv[10],
    "observed_chat_url_after": sys.argv[11],
    "chat_match": sys.argv[12],
    "fail_kind": sys.argv[13],
    "fail_reason": sys.argv[14],
    "task_hash": sys.argv[15],
    "task_nonce": sys.argv[16],
    "result_json": sys.argv[17],
    "stdout_file": sys.argv[18],
    "task_file": sys.argv[19],
}, ensure_ascii=False))
PY

  python3 - \
    "$agent_id" "$attempt" "$spawn_rc" "$child_run_id" "$status" "$exit_code" "$browser_used" "$duration_sec" \
    "$chat_url_assigned" "$chat_url_assigned" "$observed_chat_url_before" "$observed_chat_url_after" "$chat_match" "$fail_kind" "$fail_reason" \
    "$task_hash" "$task_nonce" "$child_result_json" "$out_file" "$task_file" <<'PY' >>"$SUMMARY_CSV"
import csv, sys
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(sys.argv[1:])
PY
}

run_batch() {
  local attempt="$1"
  shift
  local -a agents=("$@")
  local -a running_pids=()
  local -a running_agents=()
  local fail_count=0
  local stop_launch=0

  for agent_id in "${agents[@]}"; do
    if (( POOL_ABORT == 1 )); then
      stop_launch=1
    fi
    ensure_fleet_monitor_alive "attempt_${attempt}_before_launch_${agent_id}"
    if [[ "$stop_launch" == "1" ]]; then
      FINAL_RC["$agent_id"]="${POOL_ABORT_RC:-99}"
      mkdir -p "$POOL_AGENT_DIR/agent_${agent_id}"
      out_file="$POOL_AGENT_DIR/agent_${agent_id}/attempt_${attempt}.stdout"
      : >"$out_file"
      FINAL_OUT["$agent_id"]="$out_file"
      FINAL_ATTEMPT["$agent_id"]="$attempt"
      append_summary_for_attempt "$agent_id" "$attempt" "${POOL_ABORT_RC:-99}" "$out_file"
      continue
    fi

    out_file="$POOL_AGENT_DIR/agent_${agent_id}/attempt_${attempt}.stdout"
    run_one_agent_attempt "$agent_id" "$attempt" "$out_file" &
    pid=$!
    track_active_spawn_pid "$pid"
    running_pids+=("$pid")
    running_agents+=("$agent_id")

    while (( ${#running_pids[@]} >= CONCURRENCY )); do
      if (( POOL_ABORT == 1 )); then
        stop_launch=1
      fi
      ensure_fleet_monitor_alive "attempt_${attempt}_before_wait"
      pid0="${running_pids[0]}"
      agent0="${running_agents[0]}"
      set +e
      wait "$pid0"
      rc0=$?
      set -e
      untrack_active_spawn_pid "$pid0"
      out0="$POOL_AGENT_DIR/agent_${agent0}/attempt_${attempt}.stdout"
      FINAL_RC["$agent0"]="$rc0"
      FINAL_OUT["$agent0"]="$out0"
      FINAL_ATTEMPT["$agent0"]="$attempt"
      append_summary_for_attempt "$agent0" "$attempt" "$rc0" "$out0"
      ensure_fleet_monitor_alive "attempt_${attempt}_after_wait_${agent0}"
      if [[ "$rc0" != "0" ]]; then
        fail_count=$((fail_count + 1))
      fi
      running_pids=("${running_pids[@]:1}")
      running_agents=("${running_agents[@]:1}")
      if (( FAIL_FAST_AFTER > 0 )) && (( fail_count >= FAIL_FAST_AFTER )); then
        stop_launch=1
        break
      fi
    done
  done

  for idx in "${!running_pids[@]}"; do
    ensure_fleet_monitor_alive "attempt_${attempt}_tail_wait"
    pid="${running_pids[$idx]}"
    agent="${running_agents[$idx]}"
    set +e
    wait "$pid"
    rc=$?
    set -e
    untrack_active_spawn_pid "$pid"
    out="$POOL_AGENT_DIR/agent_${agent}/attempt_${attempt}.stdout"
    FINAL_RC["$agent"]="$rc"
    FINAL_OUT["$agent"]="$out"
    FINAL_ATTEMPT["$agent"]="$attempt"
    append_summary_for_attempt "$agent" "$attempt" "$rc" "$out"
    ensure_fleet_monitor_alive "attempt_${attempt}_after_tail_${agent}"
  done
}

declare -a ALL_AGENTS=()
for ((i=1; i<=TOTAL_AGENTS; i++)); do
  ALL_AGENTS+=("$i")
done

acquire_pool_lock
run_pool_gc_if_needed

if [[ "$FLEET_MONITOR_ENABLED" == "1" ]]; then
  if ! start_fleet_monitor "startup"; then
    watchdog_log "event=fleet_monitor_start_retry_planned"
  fi
fi

run_batch 1 "${ALL_AGENTS[@]}"

for ((attempt=2; attempt<=RETRY_MAX+1; attempt++)); do
  if (( POOL_ABORT == 1 )); then
    break
  fi
  retry_agents=()
  for agent_id in "${ALL_AGENTS[@]}"; do
    rc="${FINAL_RC[$agent_id]:-0}"
    if [[ "$rc" != "0" ]]; then
      retry_agents+=("$agent_id")
    fi
  done
  if (( ${#retry_agents[@]} == 0 )); then
    break
  fi
  run_batch "$attempt" "${retry_agents[@]}"
done

retried_count=0
for agent_id in "${ALL_AGENTS[@]}"; do
  at="${FINAL_ATTEMPT[$agent_id]:-1}"
  if (( at > 1 )); then
    retried_count=$((retried_count + 1))
  fi
done

final_stats="$(
  python3 - "$SUMMARY_JSONL" "$FINAL_SUMMARY_JSONL" "$FINAL_SUMMARY_CSV" <<'PY'
import collections
import csv
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
final_jsonl_path = pathlib.Path(sys.argv[2])
final_csv_path = pathlib.Path(sys.argv[3])
rows = [json.loads(line) for line in summary_path.read_text(encoding="utf-8").splitlines() if line.strip()]
by_agent = {}
for row in rows:
    try:
        agent = int(row.get("agent", 0))
        attempt = int(row.get("attempt", 0))
    except Exception:
        continue
    prev = by_agent.get(agent)
    if prev is None or attempt >= int(prev.get("attempt", 0)):
        by_agent[agent] = row

final_rows = [by_agent[k] for k in sorted(by_agent.keys())]
observed_map = collections.defaultdict(list)
for row in final_rows:
    observed = (row.get("observed_chat_url_after") or row.get("observed_chat_url_before") or "").strip()
    if observed:
        observed_map[observed].append(row)

for observed, items in observed_map.items():
    if len(items) <= 1:
        continue
    for row in items:
        if row.get("fail_kind", "OK") == "OK":
            row["fail_kind"] = "FAIL_DUPLICATE"
            row["fail_reason"] = "observed_chat_url_shared"

ok = 0
fail = 0
fail_breakdown = collections.Counter()
for row in final_rows:
    fk = row.get("fail_kind", "OK")
    if not fk:
        fk = "OK"
        row["fail_kind"] = fk
    if fk == "OK":
        row["final_status"] = "ok"
        ok += 1
    else:
        row["final_status"] = "failed"
        fail += 1
        fail_breakdown[fk] += 1

final_jsonl_path.parent.mkdir(parents=True, exist_ok=True)
with final_jsonl_path.open("w", encoding="utf-8") as fp:
    for row in final_rows:
        fp.write(json.dumps(row, ensure_ascii=False) + "\n")

header = [
    "agent",
    "attempt",
    "spawn_rc",
    "child_run_id",
    "status",
    "exit_code",
    "browser_used",
    "duration_sec",
    "chat_url",
    "assigned_chat_url",
    "observed_chat_url_before",
    "observed_chat_url_after",
    "chat_match",
    "fail_kind",
    "fail_reason",
    "task_hash",
    "task_nonce",
    "result_json",
    "stdout_file",
    "task_file",
    "final_status",
]
with final_csv_path.open("w", encoding="utf-8", newline="") as fp:
    w = csv.DictWriter(fp, fieldnames=header)
    w.writeheader()
    for row in final_rows:
        w.writerow({k: row.get(k, "") for k in header})

print(f"FINAL_OK={ok}")
print(f"FINAL_FAIL={fail}")
print("FINAL_FAIL_BREAKDOWN=" + json.dumps(dict(sorted(fail_breakdown.items())), ensure_ascii=False))
PY
)"

ok_count="$(printf '%s\n' "$final_stats" | sed -n 's/^FINAL_OK=//p' | tail -n 1)"
fail_count="$(printf '%s\n' "$final_stats" | sed -n 's/^FINAL_FAIL=//p' | tail -n 1)"
fail_breakdown="$(printf '%s\n' "$final_stats" | sed -n 's/^FINAL_FAIL_BREAKDOWN=//p' | tail -n 1)"
if [[ -z "$ok_count" ]] || [[ -z "$fail_count" ]]; then
  echo "failed to compute final summary counters" >&2
  exit 17
fi
if [[ -z "$fail_breakdown" ]]; then
  fail_breakdown="{}"
fi

if ! run_fleet_gate; then
  watchdog_log "event=fleet_gate_failed rc=${FLEET_GATE_RC} reason=${FLEET_GATE_REASON} counts_json=${FLEET_GATE_COUNTS_JSON}"
else
  watchdog_log "event=fleet_gate_pass counts_json=${FLEET_GATE_COUNTS_JSON}"
fi

pool_status="OK"
pool_exit_rc=0
if (( fail_count > 0 )); then
  pool_status="FAILED"
  pool_exit_rc=1
fi
if [[ "$FLEET_GATE_STATUS" == "FAIL" ]]; then
  pool_status="FAILED"
  pool_exit_rc=1
fi
if (( POOL_ABORT == 1 )); then
  pool_status="INTERRUPTED"
  pool_exit_rc="${POOL_ABORT_RC:-130}"
fi

echo "POOL_RUN_ID=$POOL_RUN_ID"
echo "POOL_RUN_DIR=$POOL_RUN_DIR"
echo "POOL_RUNS_ROOT=$POOL_RUNS_ROOT"
echo "POOL_GC_ROOT=$POOL_RUNS_ROOT"
echo "POOL_GC_APPLIED=$POOL_GC_APPLIED"
echo "POOL_GC_REASON=$POOL_GC_REASON"
echo "POOL_GC_RC=$POOL_GC_EXIT_CODE"
echo "POOL_GC_LOG=$POOL_GC_LOG"
echo "POOL_MODE=$MODE"
echo "POOL_LOCK_FILE=$POOL_LOCK_FILE"
echo "POOL_TOTAL=$TOTAL_AGENTS"
echo "POOL_OK=$ok_count"
echo "POOL_FAIL=$fail_count"
echo "POOL_RETRIED=$retried_count"
echo "POOL_SUMMARY_JSONL=$SUMMARY_JSONL"
echo "POOL_SUMMARY_CSV=$SUMMARY_CSV"
echo "POOL_FINAL_SUMMARY_JSONL=$FINAL_SUMMARY_JSONL"
echo "POOL_FINAL_SUMMARY_CSV=$FINAL_SUMMARY_CSV"
echo "POOL_FLEET_REGISTRY=$FLEET_REGISTRY_FILE"
echo "POOL_FLEET_ROSTER_JSONL=$FLEET_ROSTER_JSONL"
echo "POOL_FLEET_MONITOR_LOG=$FLEET_MONITOR_LOG"
echo "POOL_FLEET_MONITOR_PID_FILE=$FLEET_MONITOR_PID_FILE"
echo "POOL_FLEET_SUMMARY_JSON=$FLEET_SUMMARY_JSON"
echo "POOL_FLEET_SUMMARY_CSV=$FLEET_SUMMARY_CSV"
echo "POOL_FLEET_HEARTBEAT_FILE=$FLEET_HEARTBEAT_FILE"
echo "POOL_FLEET_EVENTS_JSONL=$FLEET_EVENTS_JSONL"
echo "POOL_FLEET_GATE_LOG=$FLEET_GATE_LOG"
echo "POOL_FLEET_GATE_STATUS=$FLEET_GATE_STATUS"
echo "POOL_FLEET_GATE_REASON=$FLEET_GATE_REASON"
echo "POOL_FLEET_GATE_RC=$FLEET_GATE_RC"
echo "POOL_FLEET_GATE_DISK_STATUS=$FLEET_GATE_DISK_STATUS"
echo "POOL_FLEET_GATE_EXPECTED_TOTAL=$FLEET_GATE_EXPECTED_TOTAL"
echo "POOL_FLEET_GATE_OBSERVED_TOTAL=$FLEET_GATE_OBSERVED_TOTAL"
echo "POOL_FLEET_GATE_COMPLETED_TOTAL=$FLEET_GATE_COMPLETED_TOTAL"
echo "POOL_FLEET_GATE_MISSING_ARTIFACTS_TOTAL=$FLEET_GATE_MISSING_ARTIFACTS_TOTAL"
echo "POOL_CHAT_OK_TOTAL=$FLEET_CHAT_OK_TOTAL"
echo "POOL_CHAT_MISMATCH_TOTAL=$FLEET_CHAT_MISMATCH_TOTAL"
echo "POOL_CHAT_UNKNOWN_TOTAL=$FLEET_CHAT_UNKNOWN_TOTAL"
echo "POOL_STRICT_CHAT_PROOF=$POOL_STRICT_CHAT_PROOF_EFFECTIVE"
echo "POOL_FLEET_GATE_COUNTS_JSON=$FLEET_GATE_COUNTS_JSON"
echo "POOL_FLEET_WATCHDOG_RESTARTS=$FLEET_WATCHDOG_RESTARTS"
echo "POOL_WATCHDOG_LOG=$POOL_WATCHDOG_LOG"
echo "POOL_ABORT=$POOL_ABORT"
echo "POOL_ABORT_SIGNAL=${POOL_ABORT_SIGNAL:-none}"
echo "POOL_ABORT_KILLED=$POOL_ABORT_KILLED"
echo "POOL_ABORT_REMAINING=$POOL_ABORT_REMAINING"
echo "POOL_FAIL_BREAKDOWN_JSON=$fail_breakdown"
echo "POOL_STATUS=$pool_status"

release_pool_lock

if (( pool_exit_rc != 0 )); then
  exit "$pool_exit_rc"
fi

exit 0
