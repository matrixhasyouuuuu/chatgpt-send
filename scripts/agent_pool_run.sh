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
for n in "$CONCURRENCY" "$ITERATIONS" "$TIMEOUT_SEC" "$FAIL_FAST_AFTER" "$RETRY_MAX"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "numeric option expected, got: $n" >&2
    exit 7
  fi
done
if [[ ! "$CHAT_POOL_CHECK" =~ ^[01]$ ]] || [[ ! "$CHAT_POOL_PROBE" =~ ^[01]$ ]] || [[ ! "$CHAT_POOL_PROBE_NO_SEND" =~ ^[01]$ ]]; then
  echo "chat pool switches must be 0 or 1" >&2
  exit 7
fi
if (( CONCURRENCY < 1 )); then
  echo "--concurrency must be >= 1" >&2
  exit 8
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

if [[ -z "$LOG_DIR" ]]; then
  POOL_RUN_ID="pool-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  LOG_DIR="$ROOT_DIR/state/runs/$POOL_RUN_ID"
else
  POOL_RUN_ID="$(basename "$LOG_DIR")"
fi

POOL_RUN_DIR="$LOG_DIR"
POOL_AGENT_DIR="$POOL_RUN_DIR/agents"
POOL_TASK_DIR="$POOL_RUN_DIR/tasks"
POOL_RESULT_DIR="$POOL_RUN_DIR/results"
mkdir -p "$POOL_AGENT_DIR" "$POOL_TASK_DIR" "$POOL_RESULT_DIR"

SUMMARY_JSONL="$POOL_RUN_DIR/summary.jsonl"
SUMMARY_CSV="$POOL_RUN_DIR/summary.csv"
FINAL_SUMMARY_JSONL="$POOL_RUN_DIR/summary.final.jsonl"
FINAL_SUMMARY_CSV="$POOL_RUN_DIR/summary.final.csv"
printf 'agent,attempt,spawn_rc,child_run_id,status,exit_code,browser_used,duration_sec,chat_url,assigned_chat_url,observed_chat_url_before,observed_chat_url_after,chat_match,fail_kind,fail_reason,task_hash,task_nonce,result_json,stdout_file,task_file\n' >"$SUMMARY_CSV"
: >"$SUMMARY_JSONL"

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

run_one_agent_attempt() {
  local agent_id="$1"
  local attempt="$2"
  local out_file="$3"
  local task_file="${TASK_FILE_BY_AGENT[$agent_id]}"
  local chat_url="${CHAT_BY_AGENT[$agent_id]}"

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
  local child_result_json=""
  child_run_id="$(sed -n 's/^CHILD_RUN_ID=//p' "$out_file" | tail -n 1 || true)"
  child_result_json="$(sed -n 's/^CHILD_RESULT_JSON=//p' "$out_file" | tail -n 1 || true)"

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
    if [[ "$stop_launch" == "1" ]]; then
      FINAL_RC["$agent_id"]=99
      FINAL_OUT["$agent_id"]=""
      FINAL_ATTEMPT["$agent_id"]="$attempt"
      continue
    fi

    out_file="$POOL_AGENT_DIR/agent_${agent_id}/attempt_${attempt}.stdout"
    run_one_agent_attempt "$agent_id" "$attempt" "$out_file" &
    pid=$!
    running_pids+=("$pid")
    running_agents+=("$agent_id")

    while (( ${#running_pids[@]} >= CONCURRENCY )); do
      pid0="${running_pids[0]}"
      agent0="${running_agents[0]}"
      set +e
      wait "$pid0"
      rc0=$?
      set -e
      out0="$POOL_AGENT_DIR/agent_${agent0}/attempt_${attempt}.stdout"
      FINAL_RC["$agent0"]="$rc0"
      FINAL_OUT["$agent0"]="$out0"
      FINAL_ATTEMPT["$agent0"]="$attempt"
      append_summary_for_attempt "$agent0" "$attempt" "$rc0" "$out0"
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
    pid="${running_pids[$idx]}"
    agent="${running_agents[$idx]}"
    set +e
    wait "$pid"
    rc=$?
    set -e
    out="$POOL_AGENT_DIR/agent_${agent}/attempt_${attempt}.stdout"
    FINAL_RC["$agent"]="$rc"
    FINAL_OUT["$agent"]="$out"
    FINAL_ATTEMPT["$agent"]="$attempt"
    append_summary_for_attempt "$agent" "$attempt" "$rc" "$out"
  done
}

declare -a ALL_AGENTS=()
for ((i=1; i<=TOTAL_AGENTS; i++)); do
  ALL_AGENTS+=("$i")
done

run_batch 1 "${ALL_AGENTS[@]}"

for ((attempt=2; attempt<=RETRY_MAX+1; attempt++)); do
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

pool_status="OK"
if (( fail_count > 0 )); then
  pool_status="FAILED"
fi

echo "POOL_RUN_ID=$POOL_RUN_ID"
echo "POOL_RUN_DIR=$POOL_RUN_DIR"
echo "POOL_MODE=$MODE"
echo "POOL_TOTAL=$TOTAL_AGENTS"
echo "POOL_OK=$ok_count"
echo "POOL_FAIL=$fail_count"
echo "POOL_RETRIED=$retried_count"
echo "POOL_SUMMARY_JSONL=$SUMMARY_JSONL"
echo "POOL_SUMMARY_CSV=$SUMMARY_CSV"
echo "POOL_FINAL_SUMMARY_JSONL=$FINAL_SUMMARY_JSONL"
echo "POOL_FINAL_SUMMARY_CSV=$FINAL_SUMMARY_CSV"
echo "POOL_FAIL_BREAKDOWN_JSON=$fail_breakdown"
echo "POOL_STATUS=$pool_status"

if [[ "$pool_status" != "OK" ]]; then
  exit 1
fi

exit 0
