# shellcheck shell=bash
# Shared core helpers for chatgpt_send (state/db/browser primitives).
usage() {
  cat <<'EOF'
Usage:
  chatgpt_send [options] (--prompt TEXT | --prompt-file PATH | < prompt.txt)
  chatgpt_send --init-specialist
  chatgpt_send --set-chatgpt-url URL
  chatgpt_send --clear-chatgpt-url
  chatgpt_send --show-chatgpt-url
  chatgpt_send --open-browser [--chatgpt-url URL]
  chatgpt_send --sync-chatgpt-url
  chatgpt_send --list-chats
  chatgpt_send --doctor
  chatgpt_send --doctor --json
  chatgpt_send --cleanup
  chatgpt_send --graceful-restart-browser [--chatgpt-url URL]
  chatgpt_send --ack [--chatgpt-url URL]
  chatgpt_send --save-chat NAME [--chatgpt-url URL]
  chatgpt_send --use-chat NAME
  chatgpt_send --delete-chat NAME
  chatgpt_send --bundle RUN_ID
  chatgpt_send --set-active-title TEXT
  chatgpt_send --loop-init N
  chatgpt_send --loop-status
  chatgpt_send --loop-inc
  chatgpt_send --loop-clear

Options:
  --prompt TEXT
  --prompt-file PATH
  --model MODEL                 (default: gpt-5.2-pro)
  --model-strategy MODE         select|current|ignore (default: current)
  --keep-browser / --no-keep-browser
  --manual-login / --no-manual-login (default: manual-login)
  --chrome-path PATH            (default: bin/chrome_no_sandbox)
  --chatgpt-url URL
  --chat-id ID                  shortcut for https://chatgpt.com/c/ID
  --init-specialist             open browser (if needed) and send bootstrap prompt to create/pin a new Specialist chat
  --topic TEXT                  (with --init-specialist) short task/topic; used as first message and saved in sessions list
  --set-chatgpt-url URL         persist default chat URL (same chat every run)
  --clear-chatgpt-url           remove persisted default chat URL
  --show-chatgpt-url            print persisted/default chat URL and exit
  --open-browser                open the automation Chrome/profile and exit
  --sync-chatgpt-url            detect current chat URL from open tabs and persist it
  --print-chatgpt-url           print resolved URL to stderr on each run
  --list-chats                  list saved Specialist chats (name -> url)
  --doctor                      print a quick health report (CDP, pinned chat, sessions)
  --json                        with --doctor: output one JSON line snapshot
  --cleanup                     cleanup stale pid artifacts for this profile/cdp port
  --graceful-restart-browser    restart automation Chrome safely + post-check contract/precheck
  --ack                         mark the latest tracked reply in current chat as consumed
  --save-chat NAME              save current/resolved chat as NAME
  --use-chat NAME               switch active chat to NAME
  --delete-chat NAME            remove saved chat NAME
  --bundle RUN_ID              create evidence tar.gz for run_id (state/runs/<run_id>/evidence)
  --set-active-title TEXT       set the title for the active Specialist session (for easier session list browsing)
  --loop-init N                 set loop max iterations for active Specialist session (done=0)
  --loop-status                 show loop status for active session (done/max)
  --loop-inc                    increment loop done for active session (caps at max)
  --loop-clear                  clear loop state for active session
  (writes session list to state/sessions.md automatically)
  --cdp-port PORT               DevTools port for the shared Chrome (default: 9222)
  --timeout SECONDS|auto
  --attach PATH_OR_GLOB         (repeatable)
  --dry-run                     (do not open browser; shows preview)
EOF
}

resolve_timeout_seconds() {
  # TIMEOUT is either "auto" or a number of seconds.
  if [[ "${TIMEOUT:-auto}" == "auto" ]]; then
    # Default can be overridden via env for child-agent flows where hanging
    # for 15 minutes is too expensive.
    if [[ "${CHATGPT_SEND_AUTO_TIMEOUT_SEC:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "${CHATGPT_SEND_AUTO_TIMEOUT_SEC}"
      return 0
    fi
    # Fallback default: give the web UI enough time, but don't hang forever.
    echo "900"
    return 0
  fi
  # Best-effort numeric parse; fallback to 900.
  if [[ "${TIMEOUT:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "$TIMEOUT"
    return 0
  fi
  echo "900"
}

emit_wait_only_block() {
  local action="${1:-unknown}"
  echo "E_USER_REQUEST_WAIT_ONLY action=${action} run_id=${RUN_ID}" >&2
  exit 74
}

emit_target_chat_required() {
  local got="${1:-none}"
  echo "E_TARGET_CHAT_REQUIRED got=${got} run_id=${RUN_ID}" >&2
  exit 72
}

emit_chat_state_mismatch() {
  local active_url="${1:-none}"
  local pinned_url="${2:-none}"
  echo "E_CHAT_STATE_MISMATCH active_url=${active_url} pinned_url=${pinned_url} run_id=${RUN_ID}" >&2
  exit 72
}

emit_protect_chat_mismatch() {
  local expected="${1:-none}"
  local got="${2:-none}"
  echo "E_PROTECT_CHAT_MISMATCH expected=${expected} got=${got} run_id=${RUN_ID}" >&2
  exit 78
}

log_action() {
  local action="$1"
  shift || true
  local extra="$*"
  if [[ -n "${extra//[[:space:]]/}" ]]; then
    echo "action=${action} run_id=${RUN_ID} ${extra}" >&2
  else
    echo "action=${action} run_id=${RUN_ID}" >&2
  fi
}

extract_prompt_iteration_prefix() {
  # Prints: "<iter> <max>" if prompt starts with "Iteration X/Y", else empty.
  python3 -c '
import re,sys
text=sys.stdin.read()
line=""
if text:
    line=(text.splitlines() or [""])[0]
m=re.match(r"^\s*Iteration\s+(\d+)\s*/\s*(\d+)\b", line, flags=re.IGNORECASE)
if not m:
    raise SystemExit(0)
print(f"{int(m.group(1))} {int(m.group(2))}")
'
}

chats_db_loop_expected_iteration() {
  # Prints: "<expected_iter> <loop_max> <loop_done>" for active session, else empty.
  local active
  active="$(chats_db_get_active_name | head -n 1 || true)"
  [[ -n "${active:-}" ]] || return 0
  chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
c=(db.get("chats") or {}).get(active) or {}
lm=c.get("loop_max")
if lm is None:
    raise SystemExit(0)
try:
    lm=int(lm)
except Exception:
    raise SystemExit(0)
if lm <= 0:
    raise SystemExit(0)
try:
    ld=int(c.get("loop_done") or 0)
except Exception:
    ld=0
if ld < 0:
    ld=0
if ld > lm:
    ld=lm
expected=ld + 1
if expected > lm:
    expected = lm
print(f"{expected} {lm} {ld}")
' "$active"
}

now_ms() {
  date +%s%3N 2>/dev/null || python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
}

cdp_is_up() {
  if mock_transport_enabled; then
    return 1
  fi
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1
}

is_chat_conversation_url() {
  # ChatGPT chat URLs look like: https://chatgpt.com/c/<uuid-ish>
  # We accept hex+hyphen IDs (what ChatGPT currently uses).
  local u="${1:-}"
  [[ "$u" =~ ^https://chatgpt\.com/c/[0-9a-fA-F-]{16,}$ ]]
}

wait_for_cdp() {
  # Wait up to ~6s for Chrome DevTools to become reachable.
  local i
  for i in {1..12}; do
    if cdp_is_up; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

cdp_recover_single_flight() {
  # Serialize CDP/browser recovery and apply a short cooldown to avoid
  # restart storms when several agents hit transient CDP errors together.
  local reason="$1"
  local url="$2"
  local cooldown now last wait_s recover_rc lock_fd
  cooldown="$CDP_RECOVER_COOLDOWN_SEC"
  if [[ ! "$cooldown" =~ ^[0-9]+$ ]]; then
    cooldown=2
  fi

  _recover_body() {
    now="$(date +%s)"
    last=0
    if [[ -f "$CDP_RECOVER_LAST_TS_FILE" ]]; then
      last="$(cat "$CDP_RECOVER_LAST_TS_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    wait_s=0
    if (( cooldown > 0 )) && (( now > 0 )) && (( last > 0 )) && (( now - last < cooldown )); then
      wait_s=$((cooldown - (now - last)))
    fi
    if (( wait_s > 0 )); then
      echo "[P4] cdp_recover cooldown_wait=${wait_s}s reason=${reason} run_id=${RUN_ID}" >&2
      sleep "$wait_s"
    fi
    echo "[P4] cdp_recover single_flight reason=${reason} url=${url} run_id=${RUN_ID}" >&2
    open_browser_impl "$url"
    recover_rc=$?
    date +%s >"$CDP_RECOVER_LAST_TS_FILE" 2>/dev/null || true
    return "$recover_rc"
  }

  mkdir -p "$(dirname "$CDP_RECOVER_LOCK_FILE")" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$CDP_RECOVER_LAST_TS_FILE")" >/dev/null 2>&1 || true
  if command -v flock >/dev/null 2>&1; then
    exec {lock_fd}>"$CDP_RECOVER_LOCK_FILE" || return 1
    if flock -x -w "$CDP_RECOVER_LOCK_TIMEOUT_SEC" "$lock_fd"; then
      _recover_body
      recover_rc=$?
      flock -u "$lock_fd" >/dev/null 2>&1 || true
      exec {lock_fd}>&- || true
      return "$recover_rc"
    fi
    echo "E_CDP_RECOVER_LOCK_TIMEOUT reason=${reason} file=${CDP_RECOVER_LOCK_FILE} run_id=${RUN_ID}" >&2
    exec {lock_fd}>&- || true
    return 1
  fi
  _recover_body
}

maybe_cdp_recover() {
  local reason="$1"
  local url="$2"
  local budget="$CDP_RECOVER_BUDGET"
  if [[ ! "$budget" =~ ^[0-9]+$ ]]; then
    budget=1
  fi
  if (( CDP_RECOVER_USED >= budget )); then
    echo "E_CDP_RECOVER_BUDGET_EXCEEDED used=${CDP_RECOVER_USED} budget=${budget} reason=${reason} run_id=${RUN_ID}" >&2
    return 1
  fi
  cdp_recover_single_flight "$reason" "$url"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    CDP_RECOVER_USED=$((CDP_RECOVER_USED + 1))
    echo "[P4] cdp_recover used=${CDP_RECOVER_USED}/${budget} reason=${reason} run_id=${RUN_ID}" >&2
  fi
  return $rc
}

chrome_pids_for_profile() {
  # Print PIDs of Chrome processes that were launched with our user-data-dir.
  # This avoids nuking the user's normal Chrome.
  ps -eo pid=,args= | python3 -c '
import sys
profile = sys.argv[1]
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line.strip():
        continue
    try:
        pid_str, args = line.strip().split(" ", 1)
    except ValueError:
        continue
    if ("--user-data-dir=%s" % profile) in args:
        print(pid_str)
' "$PROFILE_DIR"
}

profile_size_kb() {
  local size_kb
  if [[ -d "$PROFILE_DIR" ]]; then
    size_kb="$(du -sk "$PROFILE_DIR" 2>/dev/null | awk '{print $1}' | head -n 1)"
  else
    size_kb="0"
  fi
  if [[ ! "$size_kb" =~ ^[0-9]+$ ]]; then
    size_kb="0"
  fi
  printf '%s\n' "$size_kb"
}

chrome_pid_for_port() {
  local pf pid args
  for pf in "$ROOT/state/chrome_${CDP_PORT}.pid" "${LOG_DIR:-}/cdp/chrome_${CDP_PORT}.pid"; do
    [[ -n "${pf:-}" ]] || continue
    [[ -f "$pf" ]] || continue
    pid="$(tr -d '[:space:]' <"$pf" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *"--user-data-dir=${PROFILE_DIR}"* ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
  done
  return 1
}

chrome_uptime_sec() {
  local pid elapsed
  pid="$(chrome_pid_for_port | head -n 1 || true)"
  if [[ -z "${pid:-}" ]]; then
    printf '%s\n' "0"
    return 0
  fi
  elapsed="$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ ! "$elapsed" =~ ^[0-9]+$ ]]; then
    elapsed="0"
  fi
  printf '%s\n' "$elapsed"
}

latest_run_dir() {
  local run_dir
  run_dir="$(ls -1dt "$ROOT"/state/runs/*/ 2>/dev/null | head -n 1 || true)"
  run_dir="${run_dir%/}"
  printf '%s\n' "$run_dir"
}

recoveries_in_run() {
  local run_dir="$1"
  local count
  if [[ -z "${run_dir//[[:space:]]/}" ]] || [[ ! -d "$run_dir" ]]; then
    printf '%s\n' "0"
    return 0
  fi
  count="$(
    grep -RhsE '\[P4\] cdp_recover used=|E_CDP_TIMEOUT_RETRY|REPLY_WAIT recovery=soft_reset' "$run_dir" 2>/dev/null \
      | wc -l | tr -d '[:space:]'
  )"
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    count="0"
  fi
  printf '%s\n' "$count"
}

cleanup_runtime_artifacts() {
  local killed=0
  local pidfiles=()
  local seen=""
  local pf pid args

  pidfiles+=("$ROOT/state/chrome_${CDP_PORT}.pid")
  if [[ -n "${LOG_DIR:-}" ]]; then
    pidfiles+=("${LOG_DIR}/cdp/chrome_${CDP_PORT}.pid")
  fi

  for pf in "${pidfiles[@]}"; do
    [[ -n "${pf:-}" ]] || continue
    if [[ "$seen" == *"|$pf|"* ]]; then
      continue
    fi
    seen="${seen}|$pf|"
    [[ -e "$pf" ]] || continue
    pid="$(tr -d '[:space:]' <"$pf" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *"--user-data-dir=${PROFILE_DIR}"* ]]; then
        kill "$pid" 2>/dev/null || true
        killed=$((killed+1))
      fi
    fi
    rm -f "$pf" 2>/dev/null || true
  done

  # Remove stale pid files (empty, invalid, or dead) from local state roots.
  while IFS= read -r pf; do
    [[ -n "${pf:-}" ]] || continue
    pid="$(tr -d '[:space:]' <"$pf" 2>/dev/null || true)"
    if [[ -z "${pid:-}" ]] || [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pf" 2>/dev/null || true
    fi
  done < <(
    {
      find "$ROOT/state" -type f -name 'chrome_*.pid' 2>/dev/null || true
      if [[ -n "${LOG_DIR:-}" ]]; then
        find "${LOG_DIR}/cdp" -type f -name 'chrome_*.pid' 2>/dev/null || true
      fi
    } | sort -u
  )

  echo "CLEANUP_KILLED_TOTAL=${killed} run_id=${RUN_ID}" >&2
  echo "CLEANUP_DONE run_id=${RUN_ID}" >&2
}

stop_profile_chrome() {
  local wait_sec=5
  local deadline now pid
  local still_alive
  local pids=()
  mapfile -t pids < <(chrome_pids_for_profile 2>/dev/null || true)
  if [[ ${#pids[@]} -eq 0 ]]; then
    return 0
  fi
  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  deadline=$(( $(date +%s) + wait_sec ))
  while true; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      break
    fi
    still_alive=0
    for pid in "${pids[@]}"; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if kill -0 "$pid" 2>/dev/null; then
        still_alive=1
        break
      fi
    done
    if [[ $still_alive -eq 0 ]]; then
      return 0
    fi
    sleep 0.2
  done
  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  return 0
}

graceful_restart_browser() {
  local reason="${1:-manual}"
  local target_url="${2:-https://chatgpt.com/}"
  local st=0
  local had_errexit=0
  case "$-" in
    *e*) had_errexit=1 ;;
  esac

  if [[ "$ALLOW_BROWSER_RESTART" != "1" ]]; then
    echo "E_RESTART_NOT_ALLOWED action=graceful_restart run_id=${RUN_ID}" >&2
    return 79
  fi

  echo "BROWSER_RESTART start reason=${reason} url=${target_url} run_id=${RUN_ID}" >&2
  stop_profile_chrome || true
  cleanup_runtime_artifacts || true
  if ! open_browser_impl "$target_url"; then
    echo "E_BROWSER_RESTART_FAILED stage=open_browser reason=${reason} url=${target_url} run_id=${RUN_ID}" >&2
    return 1
  fi

  set +e
  python3 "$ROOT/bin/cdp_chatgpt.py" \
    --cdp-port "$CDP_PORT" \
    --chatgpt-url "${target_url:-https://chatgpt.com/}" \
    --timeout "20" \
    --prompt "restart_postcheck" \
    --probe-contract >/dev/null
  st=$?
  if [[ $had_errexit -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ $st -ne 0 ]]; then
    echo "E_BROWSER_RESTART_FAILED stage=probe_contract status=${st} reason=${reason} url=${target_url} run_id=${RUN_ID}" >&2
    return 1
  fi

  if is_chat_conversation_url "$target_url"; then
    set +e
    python3 "$ROOT/bin/cdp_chatgpt.py" \
      --cdp-port "$CDP_PORT" \
      --chatgpt-url "$target_url" \
      --timeout "30" \
      --prompt "restart_postcheck" \
      --precheck-only >/dev/null
    st=$?
    if [[ $had_errexit -eq 1 ]]; then
      set -e
    else
      set +e
    fi
    if [[ $st -ne 0 ]] && [[ $st -ne 10 ]]; then
      echo "E_BROWSER_RESTART_FAILED stage=precheck status=${st} reason=${reason} url=${target_url} run_id=${RUN_ID}" >&2
      return 1
    fi
  fi

  echo "BROWSER_RESTART done ok=1 reason=${reason} url=${target_url} run_id=${RUN_ID}" >&2
  return 0
}

timeout_budget_file_path() {
  printf '%s\n' "${CHATGPT_SEND_TIMEOUT_BUDGET_FILE:-$ROOT/state/timeout_budget_events.log}"
}

timeout_budget_record_event() {
  local kind="${1:-status4_timeout}"
  local window max now file tmp count_total count_runtime count_composer
  window="$TIMEOUT_BUDGET_WINDOW_SEC"
  max="$TIMEOUT_BUDGET_MAX"
  [[ "$window" =~ ^[0-9]+$ ]] || window=300
  [[ "$max" =~ ^[0-9]+$ ]] || max=3
  if (( max <= 0 )); then
    return 0
  fi
  now="$(date +%s)"
  file="$(timeout_budget_file_path)"
  mkdir -p "$(dirname "$file")" >/dev/null 2>&1 || true
  touch "$file" >/dev/null 2>&1 || true
  printf '%s\t%s\n' "$now" "$kind" >>"$file"

  tmp="$(mktemp)"
  awk -F '\t' -v now="$now" -v window="$window" '
    NF >= 1 {
      ts = $1 + 0
      if (ts >= (now - window)) print $0
    }
  ' "$file" >"$tmp" 2>/dev/null || true
  mv "$tmp" "$file" >/dev/null 2>&1 || true

  count_total="$(wc -l <"$file" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$count_total" =~ ^[0-9]+$ ]] || count_total=0
  count_runtime="$(grep -c $'\truntime_eval' "$file" 2>/dev/null || true)"
  [[ "$count_runtime" =~ ^[0-9]+$ ]] || count_runtime=0
  count_composer="$(grep -c $'\tcomposer' "$file" 2>/dev/null || true)"
  [[ "$count_composer" =~ ^[0-9]+$ ]] || count_composer=0

  echo "TIMEOUT_BUDGET event=${kind} total=${count_total} runtime_eval=${count_runtime} composer=${count_composer} max=${max} window_sec=${window} run_id=${RUN_ID}" >&2
  if (( count_total >= max )); then
    echo "E_TIMEOUT_BUDGET_EXCEEDED runtime_eval=${count_runtime} composer=${count_composer} total=${count_total} max=${max} window_sec=${window} action=${TIMEOUT_BUDGET_ACTION} run_id=${RUN_ID}" >&2
    return 1
  fi
  return 0
}

timeout_budget_handle_exceeded() {
  local action="${TIMEOUT_BUDGET_ACTION:-restart}"
  local st=0
  case "$action" in
    restart)
      graceful_restart_browser "timeout_budget" "${CHATGPT_URL:-https://chatgpt.com/}"
      st=$?
      if [[ $st -ne 0 ]]; then
        RUN_OUTCOME="timeout_budget_restart_failed"
        return "$st"
      fi
      RUN_OUTCOME="timeout_budget_restart_ok"
      return 0
      ;;
    fail)
      capture_evidence_snapshot "E_TIMEOUT_BUDGET_EXCEEDED"
      echo "E_TIMEOUT_BUDGET_FAIL_FAST run_id=${RUN_ID}" >&2
      RUN_OUTCOME="timeout_budget_fail_fast"
      return 77
      ;;
    off|none|ignore)
      RUN_OUTCOME="timeout_budget_exceeded_ignored"
      return 0
      ;;
    *)
      echo "Warning: unknown CHATGPT_SEND_TIMEOUT_BUDGET_ACTION=${action}; ignoring budget action." >&2
      return 0
      ;;
  esac
}

stable_hash() {
  python3 -c '
import hashlib, re, sys
text = sys.stdin.read()
text = text.replace("\u00a0", " ").replace("\r\n", "\n").replace("\r", "\n")
norm = re.sub(r"\s+", " ", text.strip())
if not norm:
    print("")
else:
    print(hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest())
'
}

text_signature() {
  # Usage: text_signature <text>
  # stdout: <sha256_prefix12>:<normalized_len> (or empty)
  python3 - "${1:-}" <<'PY'
import hashlib
import re
import sys

text = (sys.argv[1] or "")
text = text.replace("\u00a0", " ").replace("\r\n", "\n").replace("\r", "\n")
norm = re.sub(r"\s+", " ", text.strip())
if not norm:
    print("")
else:
    h = hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()
    print(f"{h[:12]}:{len(norm)}")
PY
}

ledger_key_for() {
  # Usage: ledger_key_for <chat_url> <prompt_hash>
  local chat_url="${1:-}"
  local prompt_hash="${2:-}"
  if [[ -z "${chat_url//[[:space:]]/}" ]] || [[ -z "${prompt_hash//[[:space:]]/}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  python3 - "$chat_url" "$prompt_hash" <<'PY'
import hashlib
import sys
chat_url = (sys.argv[1] or "").strip()
prompt_hash = (sys.argv[2] or "").strip()
if not chat_url or not prompt_hash:
    print("")
else:
    print(hashlib.sha256((chat_url + "\n" + prompt_hash).encode("utf-8", errors="ignore")).hexdigest())
PY
}

acquire_chat_single_flight_lock() {
  # Usage: acquire_chat_single_flight_lock <chat_url>
  # Returns non-zero only when lock acquisition fails.
  local chat_url="${1:-}"
  local key lock_file timeout_s st
  CHAT_SINGLE_FLIGHT_HELD=0
  CHAT_SINGLE_FLIGHT_FILE=""
  CHAT_SINGLE_FLIGHT_KEY=""
  if [[ "${CHAT_SINGLE_FLIGHT}" != "1" ]]; then
    return 0
  fi
  if ! is_chat_conversation_url "${chat_url:-}"; then
    return 0
  fi
  timeout_s="${CHAT_SINGLE_FLIGHT_TIMEOUT_SEC:-20}"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=20
  (( timeout_s < 1 )) && timeout_s=1
  key="$(printf '%s' "$chat_url" | stable_hash | cut -c1-16)"
  [[ -n "${key:-}" ]] || key="none"
  mkdir -p "${CHAT_SINGLE_FLIGHT_LOCK_DIR}" >/dev/null 2>&1 || true
  lock_file="${CHAT_SINGLE_FLIGHT_LOCK_DIR}/chat_${key}.lock"
  CHAT_SINGLE_FLIGHT_FILE="$lock_file"
  CHAT_SINGLE_FLIGHT_KEY="$key"
  if ! command -v flock >/dev/null 2>&1; then
    echo "W_CHAT_SINGLE_FLIGHT_NO_FLOCK key=${key} chat_url=${chat_url} run_id=${RUN_ID}" >&2
    return 0
  fi
  exec {CHAT_SINGLE_FLIGHT_FD}>"$lock_file"
  set +e
  flock -x -w "$timeout_s" -E 75 "$CHAT_SINGLE_FLIGHT_FD"
  st=$?
  set -e
  if [[ $st -ne 0 ]]; then
    exec {CHAT_SINGLE_FLIGHT_FD}>&- || true
    CHAT_SINGLE_FLIGHT_FILE=""
    CHAT_SINGLE_FLIGHT_KEY=""
    if [[ $st -eq 75 ]]; then
      echo "E_CHAT_SINGLE_FLIGHT_TIMEOUT key=${key} timeout_sec=${timeout_s} chat_url=${chat_url} run_id=${RUN_ID}" >&2
      return 75
    fi
    echo "E_CHAT_SINGLE_FLIGHT_FAIL key=${key} status=${st} chat_url=${chat_url} run_id=${RUN_ID}" >&2
    return "$st"
  fi
  CHAT_SINGLE_FLIGHT_HELD=1
  echo "CHAT_SINGLE_FLIGHT acquired key=${key} lock_file=${lock_file} chat_url=${chat_url} run_id=${RUN_ID}" >&2
  return 0
}

read_last_specialist_checkpoint_id() {
  if [[ -f "$LAST_SPECIALIST_CHECKPOINT_FILE" ]]; then
    python3 - "$LAST_SPECIALIST_CHECKPOINT_FILE" "$CHECKPOINT_LOCK_FILE" <<'PY'
import json
import pathlib
import sys

try:
    import fcntl
except Exception:
    fcntl = None

path = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
try:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
except Exception:
    pass
try:
    lockf = lock_path.open("a+", encoding="utf-8")
except Exception:
    lockf = None
try:
    if lockf and fcntl:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_SH)
    try:
        with path.open("r", encoding="utf-8") as f:
            obj = json.load(f)
    except Exception:
        raise SystemExit(0)
    cid = (obj.get("checkpoint_id") or "").strip()
    if cid:
        print(cid)
finally:
    if lockf and fcntl:
        try:
            fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
    if lockf:
        lockf.close()
PY
  fi
}

read_last_specialist_checkpoint_fields() {
  # Usage: read_last_specialist_checkpoint_fields
  # stdout (US-delimited): chat_url \x1f chat_id \x1f fingerprint_v1 \x1f checkpoint_id \x1f last_user_text_sig
  if [[ -f "$LAST_SPECIALIST_CHECKPOINT_FILE" ]]; then
    python3 - "$LAST_SPECIALIST_CHECKPOINT_FILE" "$CHECKPOINT_LOCK_FILE" <<'PY'
import json
import pathlib
import sys

try:
    import fcntl
except Exception:
    fcntl = None

path = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
try:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
except Exception:
    pass
try:
    lockf = lock_path.open("a+", encoding="utf-8")
except Exception:
    lockf = None
try:
    if lockf and fcntl:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_SH)
    try:
        with path.open("r", encoding="utf-8") as f:
            obj = json.load(f)
    except Exception:
        raise SystemExit(0)
    vals = [
        str(obj.get("chat_url") or "").strip(),
        str(obj.get("chat_id") or "").strip(),
        str(obj.get("fingerprint_v1") or "").strip(),
        str(obj.get("checkpoint_id") or "").strip(),
        str(obj.get("last_user_text_sig") or "").strip(),
    ]
    sep = "\x1f"
    vals = [v.replace(sep, " ").replace("\n", " ") for v in vals]
    print(sep.join(vals))
finally:
    if lockf and fcntl:
        try:
            fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
    if lockf:
        lockf.close()
PY
  fi
}

protocol_iter_value() {
  chats_db_read | python3 -c '
import json,sys
try:
    db=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
active=(db.get("active") or "").strip()
if not active:
    print("")
    raise SystemExit(0)
c=(db.get("chats") or {}).get(active) or {}
lm=c.get("loop_max")
ld=int(c.get("loop_done") or 0)
if lm is None:
    print("")
else:
    lm=int(lm)
    nxt=min(ld+1, lm)
    print(f"{nxt}/{lm}")
'
}

protocol_append_event() {
  # Usage: protocol_append_event <action> <status> <prompt_hash> <checkpoint_id> <meta>
  local action="${1:-unknown}"
  local status="${2:-ok}"
  local prompt_hash="${3:-}"
  local checkpoint_id="${4:-}"
  local meta="${5:-}"
  local iter
  iter="$(protocol_iter_value | head -n 1 || true)"
  mkdir -p "$(dirname "$PROTOCOL_LOG")" >/dev/null 2>&1 || true
  python3 - "$PROTOCOL_LOG" "$PROTOCOL_LOCK_FILE" "$RUN_ID" "${CHATGPT_URL:-}" "$prompt_hash" "$checkpoint_id" "$action" "$status" "$meta" "$iter" <<'PY'
import datetime as dt
import hashlib
import json
import os
import pathlib
import sys

try:
    import fcntl
except Exception:
    fcntl = None

path, lock_path, run_id, chat_url, prompt_hash, checkpoint_id, action, status, meta, iter_value = sys.argv[1:]
chat_url = (chat_url or "").strip()
prompt_hash = (prompt_hash or "").strip()
ledger_key = ""
if chat_url and prompt_hash:
    ledger_key = hashlib.sha256((chat_url + "\n" + prompt_hash).encode("utf-8", errors="ignore")).hexdigest()
obj = {
    "ts": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "run_id": run_id,
    "iter": iter_value,
    "chat_url": chat_url,
    "prompt_hash": prompt_hash,
    "ledger_key": ledger_key,
    "specialist_checkpoint_id": checkpoint_id,
    "action": action,
    "status": status,
    "meta": meta,
}
p = pathlib.Path(path)
p.parent.mkdir(parents=True, exist_ok=True)
lp = pathlib.Path(lock_path)
lp.parent.mkdir(parents=True, exist_ok=True)
with lp.open("a+", encoding="utf-8") as lf:
    if fcntl:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True) + "\n")
        f.flush()
        try:
            os.fsync(f.fileno())
        except Exception:
            pass
    if fcntl:
        fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
PY
}

protocol_prompt_state_info() {
  # Usage: protocol_prompt_state_info <prompt_hash> <chat_url>
  # stdout: state \t ledger_key \t last_event \t last_ts
  local prompt_hash="${1:-}"
  local chat_url="${2:-}"
  python3 - "$PROTOCOL_LOG" "$PROTOCOL_LOCK_FILE" "$prompt_hash" "$chat_url" <<'PY'
import hashlib
import json
import pathlib
import sys

try:
    import fcntl
except Exception:
    fcntl = None

path, lock_path, prompt_hash, chat_url = sys.argv[1], sys.argv[2], (sys.argv[3] or "").strip(), (sys.argv[4] or "").strip()
ledger_key = ""
if prompt_hash and chat_url:
    ledger_key = hashlib.sha256((chat_url + "\n" + prompt_hash).encode("utf-8", errors="ignore")).hexdigest()
p = pathlib.Path(path)
if not p.exists() or not prompt_hash or not chat_url:
    print(f"none\t{ledger_key}\tnone\t")
    raise SystemExit(0)

lp = pathlib.Path(lock_path)
lp.parent.mkdir(parents=True, exist_ok=True)
lockf = lp.open("a+", encoding="utf-8")
if fcntl:
    fcntl.flock(lockf.fileno(), fcntl.LOCK_SH)

last_send = -1
last_ready = -1
last_event = "none"
last_ts = ""
idx = 0
try:
    with p.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            idx += 1
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                sys.stderr.write(f"W_LEDGER_CORRUPT_LINE_SKIPPED line={idx}\n")
                continue
            obj_chat = (obj.get("chat_url") or "").strip()
            obj_hash = (obj.get("prompt_hash") or "").strip()
            obj_key = (obj.get("ledger_key") or "").strip()
            matched = False
            if ledger_key and obj_key:
                matched = obj_key == ledger_key
            elif obj_chat and obj_hash:
                matched = (obj_chat == chat_url and obj_hash == prompt_hash)
            if not matched:
                continue
            action = (obj.get("action") or "").strip()
            status = (obj.get("status") or "").strip()
            ts = (obj.get("ts") or "").strip()
            if action == "SEND" and status == "ok":
                last_send = idx
                last_event = "SEND"
                last_ts = ts
            if action in ("REPLY_READY", "REUSE_EXISTING") and status == "ok":
                last_ready = idx
                last_event = action
                last_ts = ts
finally:
    if fcntl:
        try:
            fcntl.flock(lockf.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
    lockf.close()

if last_send < 0:
    state = "none"
elif last_ready > last_send:
    state = "ready"
else:
    state = "pending"
print(f"{state}\t{ledger_key}\t{last_event}\t{last_ts}")
PY
}

protocol_prompt_state() {
  # Usage: protocol_prompt_state <prompt_hash> <chat_url>
  # stdout: one of none|pending|ready
  local prompt_hash="${1:-}"
  local chat_url="${2:-}"
  protocol_prompt_state_info "$prompt_hash" "$chat_url" | awk -F'\t' '{print $1}'
}

write_last_specialist_checkpoint_from_fetch() {
  # Usage: write_last_specialist_checkpoint_from_fetch <fetch_json_path>
  local fetch_json="$1"
  python3 - "$fetch_json" "$LAST_SPECIALIST_CHECKPOINT_FILE" "$CHECKPOINT_LOCK_FILE" <<'PY'
import json
import os
import pathlib
import re
import sys
import tempfile

try:
    import fcntl
except Exception:
    fcntl = None

src, dst, lock_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(src, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(1)

def norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip())

assistant_hash = (data.get("assistant_tail_hash") or "").strip()
if not assistant_hash:
    raise SystemExit(0)
assistant_len = int(data.get("assistant_tail_len") or 0)
summary = norm(data.get("assistant_preview") or data.get("assistant_text") or "")[:220]
messages = data.get("messages") or []
last_user_sig = (data.get("last_user_sig") or "").strip()
last_assistant_sig = (data.get("last_assistant_sig") or "").strip()
last_user_text_sig = (data.get("last_user_text_sig") or "").strip()
assistant_text_sig = (data.get("assistant_text_sig") or "").strip()
if not last_user_sig or not last_assistant_sig:
    for m in messages:
        role = (m.get("role") or "").strip()
        sig = (m.get("sig") or "").strip()
        if role == "user" and sig:
            last_user_sig = sig
        if role == "assistant" and sig:
            last_assistant_sig = sig
if not last_user_text_sig:
    user_text = (data.get("last_user_text") or "").strip()
    if user_text:
        import hashlib
        user_norm = norm(user_text)
        if user_norm:
            last_user_text_sig = hashlib.sha256(user_norm.encode("utf-8", errors="ignore")).hexdigest()[:12] + ":" + str(len(user_norm))
if not assistant_text_sig:
    assistant_text = (data.get("assistant_text") or "").strip()
    if assistant_text:
        import hashlib
        assistant_norm = norm(assistant_text)
        if assistant_norm:
            assistant_text_sig = hashlib.sha256(assistant_norm.encode("utf-8", errors="ignore")).hexdigest()[:12] + ":" + str(len(assistant_norm))
obj = {
    "chat_url": (data.get("url") or "").strip(),
    "chat_id": (data.get("chat_id") or "").strip(),
    "checkpoint_id": (data.get("checkpoint_id") or "").strip(),
    "assistant_tail_hash": assistant_hash,
    "assistant_tail_len": assistant_len,
    "last_user_sig": last_user_sig,
    "last_user_text_sig": last_user_text_sig,
    "last_assistant_sig": last_assistant_sig,
    "assistant_text_sig": assistant_text_sig,
    "total_messages": int(data.get("total_messages") or data.get("total") or len(messages)),
    "ui_state": (data.get("ui_state") or "").strip(),
    "ui_contract_sig": (data.get("ui_contract_sig") or "").strip(),
    "fingerprint_v1": (data.get("fingerprint_v1") or "").strip(),
    "norm_version": (data.get("norm_version") or "").strip(),
    "summary": summary,
    "ts": (data.get("ts") or "").strip(),
}
p = pathlib.Path(dst)
p.parent.mkdir(parents=True, exist_ok=True)
lp = pathlib.Path(lock_path)
lp.parent.mkdir(parents=True, exist_ok=True)
with lp.open("a+", encoding="utf-8") as lf:
    if fcntl:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{p.name}.tmp-", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
            f.flush()
            try:
                os.fsync(f.fileno())
            except Exception:
                pass
        os.replace(tmp_name, p)
    finally:
        if os.path.exists(tmp_name):
            try:
                os.unlink(tmp_name)
            except Exception:
                pass
    if fcntl:
        fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
print(obj.get("checkpoint_id") or "")
PY
}

fetch_last_extract_fields() {
  # Usage: fetch_last_extract_fields <fetch_json_path>
  # stdout (US-delimited): url \x1f user_tail_hash \x1f assistant_tail_hash \x1f checkpoint_id \x1f last_user_hash \x1f assistant_after_last_user
  local fetch_json="$1"
  python3 - "$fetch_json" <<'PY'
import json,sys
path=sys.argv[1]
with open(path,"r",encoding="utf-8") as f:
    d=json.load(f)
vals=[
  (d.get("url") or "").strip(),
  (d.get("user_tail_hash") or "").strip(),
  (d.get("assistant_tail_hash") or "").strip(),
  (d.get("checkpoint_id") or "").strip(),
  (d.get("last_user_hash") or "").strip(),
  "1" if d.get("assistant_after_last_user") else "0",
]
sep="\x1f"
vals=[v.replace(sep," ").replace("\n"," ") for v in vals]
print(sep.join(vals))
PY
}

fetch_last_extract_diag_fields() {
  # Usage: fetch_last_extract_diag_fields <fetch_json_path>
  # stdout (US-delimited): total_messages \x1f stop_visible \x1f last_user_sig \x1f last_assistant_sig \x1f chat_id \x1f ui_contract_sig \x1f fingerprint_v1 \x1f last_user_text_sig \x1f assistant_text_sig \x1f ui_state \x1f norm_version
  local fetch_json="$1"
  python3 - "$fetch_json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    d = json.load(f)
messages = d.get("messages") or []
last_user_sig = (d.get("last_user_sig") or "").strip()
last_assistant_sig = (d.get("last_assistant_sig") or "").strip()
if not last_user_sig or not last_assistant_sig:
    for m in messages:
        role = (m.get("role") or "").strip()
        sig = (m.get("sig") or "").strip()
        if role == "user" and sig:
            last_user_sig = sig
        if role == "assistant" and sig:
            last_assistant_sig = sig
vals = [
    str(int(d.get("total_messages") or d.get("total") or len(messages))),
    "1" if d.get("stop_visible") else "0",
    last_user_sig,
    last_assistant_sig,
    str(d.get("chat_id") or "").strip(),
    str(d.get("ui_contract_sig") or "").strip(),
    str(d.get("fingerprint_v1") or "").strip(),
    str(d.get("last_user_text_sig") or "").strip(),
    str(d.get("assistant_text_sig") or "").strip(),
    str(d.get("ui_state") or "").strip(),
    str(d.get("norm_version") or "").strip(),
]
sep = "\x1f"
vals = [v.replace(sep, " ").replace("\n", " ") for v in vals]
print(sep.join(vals))
PY
}

fetch_last_reuse_text_for_prompt() {
  # Usage: fetch_last_reuse_text_for_prompt <fetch_json_path> <prompt_hash>
  local fetch_json="$1"
  local prompt_hash="$2"
  python3 - "$fetch_json" "$prompt_hash" <<'PY'
import json,sys
path,prompt_hash=sys.argv[1],sys.argv[2]
with open(path,"r",encoding="utf-8") as f:
    d=json.load(f)
assistant=(d.get("assistant_text") or "").strip()
if not assistant:
    raise SystemExit(1)
if (d.get("last_user_hash") or "").strip() != (prompt_hash or "").strip():
    raise SystemExit(1)
if not bool(d.get("assistant_after_last_user")):
    raise SystemExit(1)
print(assistant)
PY
}

sanitize_file_inplace() {
  local path="$1"
  [[ "${SANITIZE_LOGS}" == "1" ]] || return 0
  [[ -f "$path" ]] || return 0
  python3 - "$path" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8", errors="ignore")
except Exception:
    raise SystemExit(0)

patterns = [
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}"), r"\1<REDACTED>"),
    (re.compile(r'(?i)("?(?:api[_-]?key|token|access_token|refresh_token|authorization|cookie|password|secret)"?\s*[:=]\s*"?)([^",\s}]+)'), r"\1<REDACTED>"),
    (re.compile(r"(?i)\b(access_token|token|api_key|apikey|password|secret)=([^&\s]+)"), r"\1=<REDACTED>"),
]

san = text
for rx, repl in patterns:
    san = rx.sub(repl, san)

if san != text:
    path.write_text(san, encoding="utf-8")
PY
}

ack_db_read() {
  if [[ -f "$ACK_DB" ]]; then
    cat "$ACK_DB" 2>/dev/null || true
  else
    printf '%s\n' '{"chats":{}}'
  fi
}

ack_db_write() {
  mkdir -p "$(dirname "$ACK_DB")" >/dev/null 2>&1 || true
  cat >"$ACK_DB"
}

ack_db_get_fields() {
  # Usage: ack_db_get_fields <chat_id>
  # stdout (US-delimited): last_reply_fingerprint \x1f consumed_fingerprint \x1f last_prompt_hash \x1f last_anchor_id
  local chat_id="$1"
  ack_db_read | python3 -c '
import json,sys
chat_id=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"chats":{}}
ch=(db.get("chats") or {}).get(chat_id) or {}
vals=[
  ch.get("last_reply_fingerprint",""),
  ch.get("last_reply_consumed_fingerprint",""),
  ch.get("last_prompt_hash_sent",""),
  ch.get("last_user_anchor_id",""),
]
sep="\x1f"
vals=[str(v).replace(sep," ").replace("\n"," ") for v in vals]
print(sep.join(vals))
' "$chat_id"
}

ack_db_mark_prompt() {
  # Usage: ack_db_mark_prompt <chat_id> <prompt_hash>
  local chat_id="$1"
  local prompt_hash="$2"
  ack_db_read | python3 -c '
import json,sys,time
chat_id,prompt_hash=sys.argv[1],sys.argv[2]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"chats":{}}
db.setdefault("chats", {})
ch=db["chats"].setdefault(chat_id, {})
ch["last_prompt_hash_sent"]=prompt_hash
ch["updated_at"]=int(time.time())
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$chat_id" "$prompt_hash" | ack_db_write
}

ack_db_mark_reply() {
  # Usage: ack_db_mark_reply <chat_id> <reply_fp> <anchor_id> <prompt_hash>
  local chat_id="$1"
  local reply_fp="$2"
  local anchor_id="$3"
  local prompt_hash="$4"
  ack_db_read | python3 -c '
import json,sys,time
chat_id,reply_fp,anchor_id,prompt_hash=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"chats":{}}
db.setdefault("chats", {})
ch=db["chats"].setdefault(chat_id, {})
ch["last_reply_fingerprint"]=reply_fp
if anchor_id:
    ch["last_user_anchor_id"]=anchor_id
if prompt_hash:
    ch["last_prompt_hash_sent"]=prompt_hash
ch["updated_at"]=int(time.time())
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$chat_id" "$reply_fp" "$anchor_id" "$prompt_hash" | ack_db_write
}

ack_db_mark_consumed() {
  # Usage: ack_db_mark_consumed <chat_id> [reply_fp]
  local chat_id="$1"
  local reply_fp="${2:-}"
  ack_db_read | python3 -c '
import json,sys,time
chat_id,reply_fp=sys.argv[1],sys.argv[2]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"chats":{}}
db.setdefault("chats", {})
ch=db["chats"].setdefault(chat_id, {})
if not reply_fp:
    reply_fp=str(ch.get("last_reply_fingerprint","") or "")
ch["last_reply_consumed_fingerprint"]=reply_fp
ch["updated_at"]=int(time.time())
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$chat_id" "$reply_fp" | ack_db_write
}

read_work_chat_url() {
  if [[ -f "$WORK_CHAT_URL_FILE" ]]; then
    cat "$WORK_CHAT_URL_FILE" | head -n 1 || true
  fi
}

write_work_chat_url() {
  local url="$1"
  [[ -n "${url//[[:space:]]/}" ]] || return 0
  mkdir -p "$(dirname "$WORK_CHAT_URL_FILE")" >/dev/null 2>&1 || true
  printf '%s\n' "$url" >"$WORK_CHAT_URL_FILE"
}

ensure_single_chat_target() {
  # In strict mode enforce that only the target /c/... tab remains.
  # action=block => fail if extra tabs are present
  # action=close => close extra tabs then continue
  local target_url="$1"
  local action="${STRICT_SINGLE_CHAT_ACTION:-block}"
  local target_id
  local others=()
  local u joined
  if [[ "${STRICT_SINGLE_CHAT}" != "1" ]]; then
    return 0
  fi
  if ! is_chat_conversation_url "$target_url"; then
    return 0
  fi
  if ! cdp_is_up; then
    return 0
  fi
  target_id="$(chat_id_from_url "$target_url" 2>/dev/null || true)"
  [[ -n "${target_id:-}" ]] || return 0
  while IFS= read -r u; do
    [[ -n "${u:-}" ]] || continue
    if [[ "$(chat_id_from_url "$u" 2>/dev/null || true)" != "$target_id" ]]; then
      others+=("$u")
    fi
  done < <(capture_chat_urls_from_cdp || true)
  if (( ${#others[@]} == 0 )); then
    return 0
  fi
  if [[ "$action" == "close" ]]; then
    cdp_cleanup_chat_tabs "$target_url" || true
    others=()
    while IFS= read -r u; do
      [[ -n "${u:-}" ]] || continue
      if [[ "$(chat_id_from_url "$u" 2>/dev/null || true)" != "$target_id" ]]; then
        others+=("$u")
      fi
    done < <(capture_chat_urls_from_cdp || true)
    if (( ${#others[@]} == 0 )); then
      return 0
    fi
  fi
  joined="$(printf '%s,' "${others[@]}" | sed 's/,$//')"
  echo "E_MULTIPLE_CHAT_TABS_BLOCKED target=${target_url} action=${action} others=${joined} run_id=${RUN_ID}" >&2
  return 1
}

chats_db_read() {
  if [[ -f "$CHATS_DB" ]]; then
    cat "$CHATS_DB" 2>/dev/null || true
  else
    printf '%s\n' '{"active":"","chats":{}}'
  fi
}

chats_db_write() {
  mkdir -p "$(dirname "$CHATS_DB")" >/dev/null 2>&1 || true
  cat >"$CHATS_DB"
}

chats_md_render() {
  chats_db_read | python3 -c '
import json,sys,datetime
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":"","chats":{}}
active=db.get("active") or ""
chats=db.get("chats") or {}

def fmt_ts(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return "-"

print("# Specialist Sessions")
print("")
print("Active:", ("`%s`" % active) if active else "(none)")
print("")
print("| Active | Name | Last used | Loop | URL | Title |")
print("|---|---|---|---|---|---|")

for name in sorted(chats.keys()):
    c=chats.get(name) or {}
    mark="*" if name==active else ""
    url=c.get("url","")
    title=(c.get("title","") or "").replace("|"," ")
    ts=fmt_ts(c.get("last_used"))
    lm=c.get("loop_max")
    ld=c.get("loop_done")
    loop="-" if lm is None else f"{ld or 0}/{lm}"
    print(f"| {mark} | `{name}` | `{ts}` | `{loop}` | `{url}` | {title} |")
' >"$CHATS_MD" 2>/dev/null || true
}

chats_db_upsert() {
  # Usage: chats_db_upsert <name> <url> [title]
  local name="$1"
  local url="$2"
  local title="${3:-}"
  chats_db_read | python3 -c '
import json,sys,time
name, url, title = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":"","chats":{}}
db.setdefault("chats", {})
db["chats"].setdefault(name, {})
db["chats"][name]["url"]=url
db["chats"][name]["last_used"]=int(time.time())
if title:
    db["chats"][name]["title"]=title
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$name" "$url" "$title" | chats_db_write
  chats_md_render
}

chats_db_set_active() {
  local name="$1"
  chats_db_read | python3 -c '
import json,sys
name=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":"","chats":{}}
db.setdefault("chats", {})
db["active"]=name
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$name" | chats_db_write
  chats_md_render
}

chats_db_delete() {
  local name="$1"
  chats_db_read | python3 -c '
import json,sys
name=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":"","chats":{}}
db.setdefault("chats", {})
db["chats"].pop(name, None)
if db.get("active")==name:
    db["active"]=""
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$name" | chats_db_write
  chats_md_render
}

chats_db_get_active_url() {
  chats_db_read | python3 -c '
import json,sys
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(0)
active=db.get("active") or ""
chats=db.get("chats") or {}
if active and active in chats and "url" in chats[active]:
    print(chats[active]["url"])
'
}

chats_db_list() {
  chats_db_read | python3 -c '
import json,sys,datetime
import re
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":"","chats":{}}
active=db.get("active") or ""
chats=db.get("chats") or {}

def fmt_ts(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return "-"

names=sorted(chats.keys())
if not names:
    print("No saved Specialist sessions.")
    sys.exit(0)

for idx, n in enumerate(names, start=1):
    c=chats[n] or {}
    mark="*" if n==active else " "
    url=c.get("url","")
    title=c.get("title","")
    ts=fmt_ts(c.get("last_used"))
    suffix=("  " + title) if title else ""
    if url and not re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]{16,}$", url):
        suffix = (suffix + " [INVALID_URL]").strip()
    # Human-friendly: index + name. User can say "continue 2" without pasting URLs.
    print("{} {}) {}  {}  {}{}".format(mark, idx, n, ts, url, suffix))
'
}

chats_db_find_name_by_url() {
  # Usage: chats_db_find_name_by_url <url>
  local url="$1"
  chats_db_read | python3 -c '
import json,sys
url=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(0)
chats=db.get("chats") or {}
for name,c in chats.items():
    if (c or {}).get("url")==url:
        print(name)
        break
' "$url"
}

chats_db_get_active_name() {
  chats_db_read | python3 -c '
import json,sys
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(0)
active=(db.get("active") or "").strip()
if active:
    print(active)
'
}

chats_db_loop_init() {
  local max="$1"
  local active
  active="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ -z "${active:-}" ]]; then
    echo "No active Specialist session. Use --use-chat NAME first." >&2
    exit 2
  fi
  chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
maxv=int(sys.argv[2])
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":active,"chats":{}}
db.setdefault("chats", {})
db["chats"].setdefault(active, {})
db["chats"][active]["loop_max"]=maxv
db["chats"][active]["loop_done"]=0
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$active" "$max" | chats_db_write
  chats_md_render
  echo "Loop set for $active: 0/$max" >&2
}

chats_db_loop_status() {
  local active
  active="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ -z "${active:-}" ]]; then
    echo "No active Specialist session." >&2
    exit 2
  fi
  chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(2)
c=(db.get("chats") or {}).get(active) or {}
lm=c.get("loop_max")
ld=c.get("loop_done") or 0
if lm is None:
    print("Loop: (not set)")
else:
    print(f"Loop: {ld}/{lm}")
' "$active"
}

chats_db_loop_inc() {
  local active
  active="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ -z "${active:-}" ]]; then
    echo "No active Specialist session." >&2
    exit 2
  fi
  out="$(chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":active,"chats":{}}
db.setdefault("chats", {})
db["chats"].setdefault(active, {})
c=db["chats"][active]
lm=c.get("loop_max")
ld=int(c.get("loop_done") or 0)
if lm is None:
    # no-op
    print(json.dumps(db, ensure_ascii=False, sort_keys=True))
    print("Loop: (not set)", file=sys.stderr)
    sys.exit(0)
lm=int(lm)
ld=min(ld+1, lm)
c["loop_done"]=ld
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
print(f"Loop: {ld}/{lm}", file=sys.stderr)
' "$active")" || true
  # python printed JSON to stdout and status to stderr; here we only need JSON.
  printf '%s\n' "$out" | head -n 1 | chats_db_write
  chats_md_render
}

chats_db_loop_clear() {
  local active
  active="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ -z "${active:-}" ]]; then
    echo "No active Specialist session." >&2
    exit 2
  fi
  chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":active,"chats":{}}
chats=db.get("chats") or {}
c=chats.get(active) or {}
for k in ["loop_max","loop_done"]:
    if k in c:
        del c[k]
if active in chats:
    chats[active]=c
db["chats"]=chats
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$active" | chats_db_write
  chats_md_render
  echo "Loop cleared for $active" >&2
}

autoname() {
  # Timestamp-based, stable ASCII name for a new Specialist session.
  date +"auto-%Y%m%d-%H%M%S"
}

slugify_ascii() {
  # ASCII-only slug for filenames/session names. Russian text will be stripped.
  # Usage: slugify_ascii "Some text" -> "some-text"
  echo "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' \
    | cut -c1-24
}

chats_db_has_name() {
  local name="$1"
  chats_db_read | python3 -c '
import json,sys
name=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(1)
chats=(db.get("chats") or {})
sys.exit(0 if name in chats else 1)
' "$name"
}

chats_db_unique_name() {
  # Usage: chats_db_unique_name <base>
  local base="$1"
  local n="$base"
  local i=2
  if [[ -z "${n//[[:space:]]/}" ]]; then
    n="$(autoname)"
  fi
  while chats_db_has_name "$n" >/dev/null 2>&1; do
    n="${base}-${i}"
    i=$((i+1))
  done
  printf '%s\n' "$n"
}

focus_chrome_window() {
  # Best-effort: raise the window for our automation profile so the user can see it.
  if ! command -v wmctrl >/dev/null 2>&1; then
    return 0
  fi
  # Some X11/WM states can make wmctrl emit BadWindow and return non-zero.
  # Never fail the whole command because of focus helpers.
  wmctrl -lx 2>/dev/null | python3 -c '
import sys
profile = sys.argv[1]
for line in sys.stdin:
    parts = line.strip().split(None, 3)
    if len(parts) < 3:
        continue
    wid = parts[0]
    wcls = parts[2]
    if profile in wcls:
        print(wid)
        break
' "$PROFILE_DIR" || true
}

cdp_open_tab() {
  # Best-effort: open a new tab in the shared Chrome instance.
  # Works only when CDP is up.
  local url="$1"
  if ! cdp_is_up; then
    return 1
  fi
  # Chrome 144+ requires PUT for /json/new; GET can return HTTP 405.
  local encoded endpoint hdr body http allow snippet
  encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url" 2>/dev/null || true)"
  [[ -z "${encoded:-}" ]] && encoded="$url"
  endpoint="http://127.0.0.1:${CDP_PORT}/json/new?${encoded}"
  hdr="$(mktemp)"
  body="$(mktemp)"

  http="$(curl -sS --max-time 2 -D "$hdr" -o "$body" -X PUT "$endpoint" -w '%{http_code}' || echo "000")"
  if [[ ! "$http" =~ ^2 ]]; then
    allow="$(awk 'tolower($1)=="allow:"{sub(/\r$/,"",$0); print $2}' "$hdr" | head -n 1 || true)"
    snippet="$(head -c 240 "$body" 2>/dev/null | tr '\n' ' ' | tr -d '\r')"
    echo "cdp_open_tab: PUT failed http=$http allow=${allow:-} body_snip=${snippet:-}" >&2

    http="$(curl -sS --max-time 2 -D "$hdr" -o "$body" -X GET "$endpoint" -w '%{http_code}' || echo "000")"
    if [[ ! "$http" =~ ^2 ]]; then
      allow="$(awk 'tolower($1)=="allow:"{sub(/\r$/,"",$0); print $2}' "$hdr" | head -n 1 || true)"
      snippet="$(head -c 240 "$body" 2>/dev/null | tr '\n' ' ' | tr -d '\r')"
      echo "[E_CDP_NEW_TAB_FAILED] cdp_open_tab: GET failed http=$http allow=${allow:-} body_snip=${snippet:-}" >&2
      export CHATGPT_SEND_ERROR_CODE="E_CDP_NEW_TAB_FAILED"
      rm -f "$hdr" "$body"
      return 1
    fi
  fi

  rm -f "$hdr" "$body"
  return 0
}

chat_id_from_url() {
  # Extract ChatGPT conversation id from a URL, if present.
  # Example: https://chatgpt.com/c/<id> -> <id>
  local u="${1:-}"
  if [[ "$u" =~ ^https://chatgpt\.com/c/([0-9a-fA-F-]{16,}).*$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

capture_chat_title_for_url_from_cdp() {
  # Usage: capture_chat_title_for_url_from_cdp <url>
  # Prints the title (may be empty) for the matching chat URL.
  local target="$1"
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,sys
target=sys.argv[1]
try:
    tabs=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in tabs:
    u=(t.get("url") or "").split("#",1)[0].strip()
    if u==target:
        print((t.get("title") or "").strip())
        break
' "$target"
}

cdp_cleanup_chat_tabs() {
  # Close extra ChatGPT conversation tabs so the user doesn't end up with a pile
  # of /c/... tabs.
  # - legacy mode: keep one target tab, close all other /c/... tabs
  # - safe mode (CHATGPT_SEND_AUTO_TAB_HYGIENE=1): never close target/pinned/active chat ids
  local target_url="$1"
  local target_id pinned_url active_url pinned_id active_id protect_pinned protect_active
  local mode close_count tab_ids
  target_id="$(chat_id_from_url "$target_url" 2>/dev/null || true)"
  if [[ -z "${target_id:-}" ]] || ! cdp_is_up; then
    return 0
  fi
  pinned_url=""
  if [[ -f "${CHATGPT_URL_FILE:-}" ]]; then
    pinned_url="$(cat "${CHATGPT_URL_FILE}" | head -n 1 || true)"
  fi
  active_url="$(chats_db_get_active_url | head -n 1 || true)"
  pinned_id="$(chat_id_from_url "${pinned_url:-}" 2>/dev/null || true)"
  active_id="$(chat_id_from_url "${active_url:-}" 2>/dev/null || true)"
  protect_pinned=0
  protect_active=0
  [[ -n "${pinned_id:-}" ]] && protect_pinned=1
  [[ -n "${active_id:-}" ]] && protect_active=1
  mode="legacy"
  if [[ "${AUTO_TAB_HYGIENE:-0}" == "1" ]]; then
    mode="safe"
  fi
  echo "TAB_HYGIENE start mode=${mode} target_id=${target_id:-none} pinned_id=${pinned_id:-none} active_id=${active_id:-none} pinned_tab_protect=${protect_pinned} active_tab_protect=${protect_active} run_id=${RUN_ID}" >&2

  close_count=0
  tab_ids="$(curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys,urllib.parse
target_id=sys.argv[1]
safe_mode=(sys.argv[2] == "1")
pinned_id=sys.argv[3]
active_id=sys.argv[4]
raw=sys.stdin.read()
try:
    tabs=json.loads(raw)
except Exception:
    sys.exit(0)

def chat_id(u:str):
    m=re.match(r"^https://chatgpt\.com/c/([0-9a-fA-F-]{16,})", u or "")
    return m.group(1) if m else None

to_close=[]
protected_ids={target_id}
if safe_mode:
    if pinned_id:
        protected_ids.add(pinned_id)
    if active_id:
        protected_ids.add(active_id)

keep_target=None
for t in tabs:
    tid=(t.get("id") or "").strip()
    u=(t.get("url") or "").split("#",1)[0].strip()
    cid=chat_id(u)
    if not cid:
        continue

    if safe_mode and cid in protected_ids:
        continue

    if cid == target_id:
        if keep_target is None:
            keep_target=tid
            continue
        to_close.append(tid)
    else:
        to_close.append(tid)

for tid in to_close:
    if tid:
        print(tid)
' "$target_id" "${AUTO_TAB_HYGIENE:-0}" "${pinned_id:-}" "${active_id:-}" || true)"
  while read -r tab_id; do
    [[ -z "${tab_id:-}" ]] && continue
    curl -fsS "http://127.0.0.1:${CDP_PORT}/json/close/${tab_id}" >/dev/null 2>&1 || true
    close_count=$((close_count + 1))
  done <<<"${tab_ids:-}"
  echo "TAB_HYGIENE done mode=${mode} closed=${close_count} target_id=${target_id:-none} pinned_tab_protect=${protect_pinned} active_tab_protect=${protect_active} run_id=${RUN_ID}" >&2
}

cdp_close_all_conversation_tabs() {
  # Close all ChatGPT conversation tabs (/c/...). Useful when starting a "new"
  # session to avoid sync ambiguity.
  if ! cdp_is_up; then
    return 0
  fi
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
try:
    tabs=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in tabs:
    tid=(t.get("id") or "").strip()
    u=(t.get("url") or "").split("#",1)[0].strip()
    if tid and re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]{16,}", u):
        print(tid)
' | while read -r tab_id; do
    [[ -z "${tab_id:-}" ]] && continue
    curl -fsS "http://127.0.0.1:${CDP_PORT}/json/close/${tab_id}" >/dev/null 2>&1 || true
  done
}

open_browser_impl() {
  # Usage: open_browser_impl <url>
  # Opens (or focuses) a shared automation Chrome instance and returns 0 on success.
  local url="$1"
  if mock_transport_enabled; then
    mock_open_browser "$url"
    return $?
  fi

  # Use a dedicated automation profile under this project (login persists).
  if [[ "$url" =~ ^https://chatgpt\.com/c/ ]] && ! is_chat_conversation_url "$url"; then
    echo "Warning: pinned chat URL is invalid; opening https://chatgpt.com/ instead." >&2
    url="https://chatgpt.com/"
  fi

  if cdp_is_up; then
    echo "Chrome already running (CDP port $CDP_PORT). Bringing its window to front..." >&2
    wid="$(focus_chrome_window | head -n 1 || true)"
    if [[ -n "${wid:-}" ]] && command -v wmctrl >/dev/null 2>&1; then
      wmctrl -ia "$wid" >/dev/null 2>&1 || true
    fi
    # By default we close existing conversation tabs when switching to home to
    # keep --sync-chatgpt-url unambiguous. Multi-child shared runs can disable
    # this via CHATGPT_SEND_PRESERVE_TABS=1 to avoid interfering with siblings.
    if [[ "$url" == "https://chatgpt.com/" ]] || [[ "$url" == "https://chatgpt.com" ]]; then
      if [[ "${PRESERVE_TABS}" != "1" ]]; then
        cdp_close_all_conversation_tabs || true
      fi
    fi
    # Activate existing tab if possible; only open a new one if missing.
    cdp_activate_or_open_url "$url" || true
    return 0
  fi

  if [[ $PRINT_URL -eq 1 ]]; then
    echo "ChatGPT URL: $url" >&2
  fi
  mkdir -p "$PROFILE_DIR" >/dev/null 2>&1 || true

  if [[ -n "${LOG_DIR:-}" ]]; then
    mkdir -p "${LOG_DIR}/cdp" >/dev/null 2>&1 || true
    chrome_log="${LOG_DIR}/cdp/chrome_${CDP_PORT}.log"
    chrome_pidfile="${LOG_DIR}/cdp/chrome_${CDP_PORT}.pid"
  else
    chrome_log="/tmp/chatgpt_send_chrome_${CDP_PORT}.log"
    chrome_pidfile="$ROOT/state/chrome_${CDP_PORT}.pid"
  fi
  rm -f "$chrome_log" >/dev/null 2>&1 || true

  # Use setsid to detach from the caller's process group/cgroup cleanup.
  setsid -f "$CHROME_PATH" \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$CDP_PORT" \
    --remote-allow-origins="http://127.0.0.1:${CDP_PORT}" \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu \
    --use-gl=swiftshader \
    --new-window \
    --user-data-dir="$PROFILE_DIR" \
    "$url" >"$chrome_log" 2>&1 || true
  : >"$chrome_pidfile" 2>/dev/null || true

  if wait_for_cdp; then
    echo "Opened Chrome (CDP port $CDP_PORT) at: $url" >&2
    wid="$(focus_chrome_window | head -n 1 || true)"
    if [[ -n "${wid:-}" ]] && command -v wmctrl >/dev/null 2>&1; then
      wmctrl -ia "$wid" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  stale_pids="$(chrome_pids_for_profile | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "${stale_pids//[[:space:]]/}" ]]; then
    echo "Chrome didn't come up (CDP $CDP_PORT). Found stale Chrome PIDs for this automation profile: $stale_pids" >&2
    echo "Trying to stop them and restart..." >&2
    for p in $stale_pids; do
      kill "$p" 2>/dev/null || true
    done
    sleep 0.8

    setsid -f "$CHROME_PATH" \
      --remote-debugging-address=127.0.0.1 \
      --remote-debugging-port="$CDP_PORT" \
      --remote-allow-origins="http://127.0.0.1:${CDP_PORT}" \
      --no-first-run \
      --no-default-browser-check \
      --disable-gpu \
      --use-gl=swiftshader \
      --new-window \
      --user-data-dir="$PROFILE_DIR" \
      "$url" >"$chrome_log" 2>&1 || true
    : >"$chrome_pidfile" 2>/dev/null || true

    if wait_for_cdp; then
      echo "Opened Chrome (CDP port $CDP_PORT) at: $url" >&2
      wid="$(focus_chrome_window | head -n 1 || true)"
      if [[ -n "${wid:-}" ]] && command -v wmctrl >/dev/null 2>&1; then
        wmctrl -ia "$wid" >/dev/null 2>&1 || true
      fi
      return 0
    fi
  fi

  echo "Failed to open a visible Chrome window. CDP is not reachable on 127.0.0.1:$CDP_PORT." >&2
  if [[ -f "$chrome_log" ]]; then
    echo "tail(chrome log):" >&2
    tail -n 120 "$chrome_log" >&2 || true
  fi
  return 1
}

capture_chat_url_from_cdp() {
  # Prints a single https://chatgpt.com/c/... URL or nothing if not found/ambiguous.
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
raw = sys.stdin.read()
try:
    tabs = json.loads(raw)
except Exception:
    sys.exit(0)

urls = []
for t in tabs:
    u = (t.get("url") or "").strip()
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]+", u):
        urls.append(u.split("#",1)[0])

uniq=[]
seen=set()
for u in urls:
    if u not in seen:
        uniq.append(u)
        seen.add(u)

if len(uniq) == 1:
    print(uniq[0])
'
}

capture_chat_urls_from_cdp() {
  # Prints all unique chat URLs (one per line).
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
raw=sys.stdin.read()
try:
    tabs=json.loads(raw)
except Exception:
    sys.exit(0)
urls=[]
for t in tabs:
    u=(t.get("url") or "").strip()
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]+", u):
        urls.append(u.split("#",1)[0])
seen=set()
for u in urls:
    if u not in seen:
        print(u)
        seen.add(u)
'
}

capture_chat_tab_from_cdp() {
  # Prints "url<TAB>title" when there is exactly one chat tab open.
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
raw = sys.stdin.read()
try:
    tabs = json.loads(raw)
except Exception:
    sys.exit(0)

hits = []
for t in tabs:
    u = (t.get("url") or "").strip()
    if not u:
        continue
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]+", u):
        hits.append((u.split("#",1)[0], (t.get("title") or "").strip()))

uniq=[]
seen=set()
for u,title in hits:
    if u not in seen:
        uniq.append((u,title))
        seen.add(u)

if len(uniq) == 1:
    u,title = uniq[0]
    print(u + "\t" + title)
'
}

capture_chat_tab_from_cdp_last() {
  # Prints "url<TAB>title" for the last chat tab in the CDP list (best-effort).
  # This is a fallback for humans: when multiple chat tabs are open, we still
  # want to sync *something* (usually the most recently created tab).
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
raw = sys.stdin.read()
try:
    tabs = json.loads(raw)
except Exception:
    sys.exit(0)

hits = []
for t in tabs:
    u = (t.get("url") or "").strip()
    if not u:
        continue
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]+", u):
        hits.append((u.split("#",1)[0], (t.get("title") or "").strip()))

uniq=[]
seen=set()
for u,title in hits:
    if u not in seen:
        uniq.append((u,title))
        seen.add(u)

if uniq:
    u,title = uniq[-1]
    print(u + "\t" + title)
'
}

capture_best_chat_tab_from_cdp() {
  # Prints "url<TAB>title" selecting the most likely "new" chat.
  # Heuristic: if multiple chat tabs exist, pick the first URL that is not yet
  # present in our chats DB; otherwise pick the last chat URL.
  curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys,os
chats_db_path=sys.argv[1]
try:
    tabs=json.load(sys.stdin)
except Exception:
    sys.exit(0)

known=set()
try:
    with open(chats_db_path,"r",encoding="utf-8") as f:
        db=json.load(f)
    for c in (db.get("chats") or {}).values():
        u=(c or {}).get("url") or ""
        if isinstance(u,str) and u.startswith("https://chatgpt.com/c/"):
            known.add(u)
except Exception:
    pass

hits=[]
for t in tabs:
    u=(t.get("url") or "").strip()
    if not u:
        continue
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]+", u):
        hits.append((u.split("#",1)[0], (t.get("title") or "").strip()))

uniq=[]
seen=set()
for u,title in hits:
    if u not in seen:
        uniq.append((u,title))
        seen.add(u)

if not uniq:
    sys.exit(0)

# Prefer an unknown URL (likely newly created chat).
for u,title in uniq:
    if u not in known:
        print(u + "\t" + title)
        sys.exit(0)

# Otherwise pick the last one.
u,title=uniq[-1]
print(u + "\t" + title)
' "$CHATS_DB"
}

cdp_activate_or_open_url() {
  # Usage: cdp_activate_or_open_url <url>
  local target="$1"
  if ! cdp_is_up; then
    return 1
  fi
  # Try to find an existing tab and activate it; otherwise open a new one.
  local tab_id
  tab_id="$(curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
target=sys.argv[1]
target=target.split("#",1)[0].strip()
target_id=None
m=re.match(r"^https://chatgpt\\.com/c/([0-9a-fA-F-]{16,})", target)
if m:
    target_id=m.group(1)
try:
    tabs=json.load(sys.stdin)
except Exception:
    sys.exit(0)

def chat_id(u:str):
    m=re.match(r"^https://chatgpt\\.com/c/([0-9a-fA-F-]{16,})", u or "")
    return m.group(1) if m else None

for t in tabs:
    u=(t.get("url") or "").split("#",1)[0].strip()
    tid=(t.get("id") or "").strip()
    if not tid:
        continue
    if target_id:
        if chat_id(u)==target_id:
            print(tid)
            break
    else:
        if u==target:
            print(tid)
            break
' "$target" | head -n 1 || true)"

  if [[ -n "${tab_id:-}" ]]; then
    curl -fsS "http://127.0.0.1:${CDP_PORT}/json/activate/${tab_id}" >/dev/null 2>&1 || true
  else
    cdp_open_tab "$target" || true
  fi
  # Raise the window so user can see the chat.
  local wid
  wid="$(focus_chrome_window | head -n 1 || true)"
  if [[ -n "${wid:-}" ]] && command -v wmctrl >/dev/null 2>&1; then
    wmctrl -ia "$wid" >/dev/null 2>&1 || true
  fi
  return 0
}
