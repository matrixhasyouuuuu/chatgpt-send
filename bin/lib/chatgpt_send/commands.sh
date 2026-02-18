# shellcheck shell=bash
# Early command handlers (list/doctor/sessions/control) for chatgpt_send.
chatgpt_send_handle_early_commands() {
# Chat database operations (human-friendly "Specialist sessions")
if [[ $LIST_CHATS -eq 1 ]]; then
  chats_db_list
  exit 0
fi

if [[ $DOCTOR -eq 1 ]]; then
  echo "DOCTOR start run_id=${RUN_ID}" >&2
  profile_size="$(profile_size_kb)"
  chrome_uptime="$(chrome_uptime_sec)"
  last_run_dir="$(latest_run_dir)"
  recoveries_count="$(recoveries_in_run "$last_run_dir")"
  restart_threshold="$RESTART_RECOMMEND_UPTIME_SEC"
  if [[ ! "$restart_threshold" =~ ^[0-9]+$ ]]; then
    restart_threshold=14400
  fi
  restart_recommended=0
  if (( chrome_uptime >= restart_threshold )) && (( recoveries_count > 0 )); then
    restart_recommended=1
  fi
  cdp_ok=0
  if cdp_is_up; then
    cdp_ok=1
  fi
  pinned=""
  if [[ -f "$CHATGPT_URL_FILE" ]]; then
    pinned="$(cat "$CHATGPT_URL_FILE" | head -n 1 || true)"
  fi
  work_chat_url="$(read_work_chat_url || true)"
  active="$(chats_db_get_active_name | head -n 1 || true)"
  active_url="$(chats_db_get_active_url | head -n 1 || true)"
  fail_count=0
  fail_keys=()
  doctor_fail() {
    local key="$1"
    local expected="$2"
    local got="$3"
    echo "E_DOCTOR_INVARIANT_FAIL key=${key} expected=${expected} got=${got} run_id=${RUN_ID}" >&2
    fail_keys+=("$key")
    fail_count=$((fail_count+1))
  }
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && ! is_chat_conversation_url "${PROTECT_CHAT_URL}"; then
    doctor_fail "protect_url_format" "conversation_url" "${PROTECT_CHAT_URL}"
  fi
  if [[ -n "${CHATGPT_SEND_FORCE_CHAT_URL:-}" ]] && ! is_chat_conversation_url "${CHATGPT_SEND_FORCE_CHAT_URL}"; then
    doctor_fail "force_url_format" "conversation_url" "${CHATGPT_SEND_FORCE_CHAT_URL}"
  fi
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && [[ -n "${CHATGPT_SEND_FORCE_CHAT_URL:-}" ]] \
    && [[ "${PROTECT_CHAT_URL}" != "${CHATGPT_SEND_FORCE_CHAT_URL}" ]]; then
    doctor_fail "force_protect_mismatch" "${PROTECT_CHAT_URL}" "${CHATGPT_SEND_FORCE_CHAT_URL}"
  fi
  invariants_ok=1
  if (( fail_count > 0 )); then
    invariants_ok=0
  fi

  if [[ $DOCTOR_JSON -eq 1 ]]; then
    python3 - "$ROOT" "$CDP_PORT" "$cdp_ok" "$pinned" "$work_chat_url" "$active" "$active_url" \
      "${CHATGPT_SEND_FORCE_CHAT_URL:-}" "${PROTECT_CHAT_URL:-}" "$PROFILE_DIR" \
      "${AUTO_WAIT_ON_GENERATION}" "${AUTO_WAIT_MAX_SEC}" "${AUTO_WAIT_POLL_MS}" \
      "${REPLY_POLLING}" "${REPLY_POLL_MS}" "${REPLY_MAX_SEC}" \
      "${CDP_RECOVER_BUDGET}" "${CDP_RECOVER_COOLDOWN_SEC}" \
      "${SHARED_BROWSER_LOCK_FILE:-${LOCK_FILE:-}}" "${STRICT_SINGLE_CHAT}" "${STRICT_SINGLE_CHAT_ACTION}" "$invariants_ok" "$fail_count" \
      "$profile_size" "$chrome_uptime" "$recoveries_count" "$restart_recommended" "$restart_threshold" "$last_run_dir" <<'PY'
import json,sys,time
(
root, cdp_port, cdp_ok, pinned, work_chat_url, active, active_url,
force_url, protect_url, profile_dir,
auto_wait_on, auto_wait_max, auto_wait_poll,
reply_polling, reply_poll_ms, reply_max_sec,
recover_budget, recover_cooldown, lock_file,
strict_single_chat, strict_single_chat_action, invariants_ok, fail_count,
profile_size_kb, chrome_uptime_s, recoveries_in_run, restart_recommended,
restart_recommend_uptime_sec, recent_run_dir
) = sys.argv[1:]
obj = {
    "ts": int(time.time()),
    "root": root,
    "cdp_port": int(cdp_port or 0),
    "cdp_ok": int(cdp_ok or 0),
    "pinned_url": pinned,
    "work_chat_url": work_chat_url,
    "active_session": active,
    "active_url": active_url,
    "force_chat_url": force_url,
    "protect_chat_url": protect_url,
    "profile_dir": profile_dir,
    "profile_dir_used": int(bool(profile_dir)),
    "force_chat_url_set": int(bool(force_url)),
    "auto_wait_on_generation": int(auto_wait_on or 0),
    "auto_wait_max_sec": int(auto_wait_max or 0),
    "auto_wait_poll_ms": int(auto_wait_poll or 0),
    "reply_polling": int(reply_polling or 0),
    "reply_poll_ms": int(reply_poll_ms or 0),
    "reply_max_sec": int(reply_max_sec or 0),
    "recover_budget": int(recover_budget or 0),
    "recover_cooldown_sec": int(recover_cooldown or 0),
    "profile_size_kb": int(profile_size_kb or 0),
    "chrome_uptime_s": int(chrome_uptime_s or 0),
    "recoveries_in_run": int(recoveries_in_run or 0),
    "restart_recommend_uptime_sec": int(restart_recommend_uptime_sec or 0),
    "restart_recommended": int(restart_recommended or 0),
    "recent_run_dir": recent_run_dir,
    "lock_file": lock_file,
    "strict_single_chat": int(strict_single_chat or 0),
    "strict_single_chat_action": strict_single_chat_action,
    "invariants_ok": int(invariants_ok or 0),
    "invariant_fail_count": int(fail_count or 0),
}
print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
PY
  else
    echo "chatgpt_send doctor"
    echo "  root: $ROOT"
    echo "  cdp_port: $CDP_PORT"
    if (( cdp_ok == 1 )); then
      echo "  cdp: OK"
    else
      echo "  cdp: DOWN"
    fi
    echo "  pinned_url: ${pinned:-"(none)"}"
    echo "  work_chat_url: ${work_chat_url:-"(none)"}"
    echo "  active_session: ${active:-"(none)"}"
    echo "  active_url: ${active_url:-"(none)"}"
    echo "  force_chat_url: ${CHATGPT_SEND_FORCE_CHAT_URL:-"(none)"}"
    echo "  protect_chat_url: ${PROTECT_CHAT_URL:-"(none)"}"
    echo "  strict_single_chat: ${STRICT_SINGLE_CHAT}"
    echo "  strict_single_chat_action: ${STRICT_SINGLE_CHAT_ACTION}"
    echo "  profile_dir: ${PROFILE_DIR}"
    echo "  profile_size_kb: ${profile_size}"
    echo "  chrome_uptime_s: ${chrome_uptime}"
    echo "  recoveries_in_run: ${recoveries_count}"
    echo "  restart_recommended: ${restart_recommended}"
    echo "  restart_recommend_uptime_sec: ${restart_threshold}"
    echo "  invariants_ok: ${invariants_ok}"
    if (( fail_count > 0 )); then
      echo "  invariant_fail_count: ${fail_count}"
      echo "  invariant_fail_keys: ${fail_keys[*]}"
    fi

    if [[ -n "${active:-}" ]]; then
      (chats_db_loop_status 2>/dev/null | sed 's/^/  /') || true
    fi

    if (( cdp_ok == 1 )); then
      echo "  open_chat_tabs:"
      curl -fsS "http://127.0.0.1:${CDP_PORT}/json/list" | python3 -c '
import json,re,sys
try:
    tabs=json.load(sys.stdin)
except Exception:
    sys.exit(0)
hits=[]
for t in tabs:
    u=(t.get("url") or "").split("#",1)[0].strip()
    if re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]{16,}", u):
        hits.append((t.get("id") or "", u, (t.get("title") or "").strip()))
for tid,u,title in hits[:12]:
    print("   -", tid, u, ("(" + title + ")") if title else "")
print("   total:", len(hits))
'
    fi
  fi
  echo "DOCTOR done invariants_ok=${invariants_ok} fail_count=${fail_count} run_id=${RUN_ID}" >&2
  if [[ "${CHATGPT_SEND_STRICT_DOCTOR:-0}" == "1" ]] && (( fail_count > 0 )); then
    exit 1
  fi
  exit 0
fi

if [[ $DO_CLEANUP -eq 1 ]]; then
  cleanup_runtime_artifacts
  exit 0
fi

if [[ $DO_GRACEFUL_RESTART -eq 1 ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "graceful_restart_browser"
  fi
  restart_url="${CHATGPT_URL:-}"
  if [[ $CHATGPT_URL_EXPLICIT -eq 1 ]] && [[ "${restart_url:-}" =~ ^https://chatgpt\.com/c/ ]] \
    && ! is_chat_conversation_url "${restart_url}"; then
    emit_target_chat_required "${restart_url}"
  fi
  if [[ -z "${restart_url//[[:space:]]/}" ]]; then
    restart_url="$(read_work_chat_url || true)"
  fi
  if [[ -z "${restart_url//[[:space:]]/}" ]] && [[ -f "$CHATGPT_URL_FILE" ]]; then
    restart_url="$(cat "$CHATGPT_URL_FILE" | head -n 1 || true)"
  fi
  if [[ -z "${restart_url//[[:space:]]/}" ]]; then
    restart_url="https://chatgpt.com/"
  fi
  graceful_restart_browser "manual" "$restart_url"
  exit $?
fi

if [[ -n "${BUNDLE_RUN_ID//[[:space:]]/}" ]]; then
  bundle_run_dir="$ROOT/state/runs/$BUNDLE_RUN_ID"
  bundle_evidence_dir="$bundle_run_dir/evidence"
  bundle_out="$bundle_run_dir/evidence-${BUNDLE_RUN_ID}.tar.gz"
  if [[ ! -d "$bundle_run_dir" ]]; then
    echo "Run dir not found: $bundle_run_dir" >&2
    exit 2
  fi
  if [[ ! -d "$bundle_evidence_dir" ]]; then
    echo "Evidence dir not found: $bundle_evidence_dir" >&2
    exit 2
  fi
  tar -czf "$bundle_out" -C "$bundle_run_dir" evidence
  echo "$bundle_out"
  exit 0
fi

if [[ -n "${SET_ACTIVE_TITLE//[[:space:]]/}" ]]; then
  active="$(chats_db_get_active_name | head -n 1 || true)"
  if [[ -z "${active:-}" ]]; then
    echo "No active Specialist session." >&2
    exit 2
  fi
  # Update title of active session.
  chats_db_read | python3 -c '
import json,sys
active=sys.argv[1]
title=sys.argv[2]
try:
    db=json.load(sys.stdin)
except Exception:
    db={"active":active,"chats":{}}
db.setdefault("chats", {})
db["chats"].setdefault(active, {})
db["chats"][active]["title"]=title
print(json.dumps(db, ensure_ascii=False, sort_keys=True))
' "$active" "$SET_ACTIVE_TITLE" | chats_db_write
  chats_md_render
  echo "Updated title for $active" >&2
  exit 0
fi

if [[ $INIT_SPECIALIST -eq 1 ]]; then
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "init_specialist"
  fi
  # Ensure a shared browser exists and force a "new chat" page. Then send the
  # bootstrap prompt which will create a /c/<id> URL that we can pin.
  open_browser_impl "https://chatgpt.com/" || exit 1
  CHATGPT_URL="https://chatgpt.com/"
  # Force explicit home target for init-specialist so stale work_chat_url
  # cannot override the "create new chat" flow.
  CHATGPT_URL_EXPLICIT=1
  topic="${INIT_TOPIC:-}"
  # Allow passing topic via --prompt/--prompt-file too.
  if [[ -z "${topic//[[:space:]]/}" ]] && [[ -n "${PROMPT//[[:space:]]/}" ]]; then
    topic="$PROMPT"
  fi
  if [[ -z "${topic//[[:space:]]/}" ]] && [[ -n "${PROMPT_FILE:-}" ]]; then
    topic="$(cat "$PROMPT_FILE" 2>/dev/null || true)"
  fi

  bootstrap="$(cat "$ROOT/docs/specialist_bootstrap.txt" 2>/dev/null || true)"
  PROMPT="$bootstrap"
  if [[ -n "${topic//[[:space:]]/}" ]]; then
    PROMPT+=$'\n\n'"Тема: ${topic}"
  fi
  PROMPT_FILE=""

  # Prepare a nicer session name/title for the newly created chat.
  if [[ -n "${topic//[[:space:]]/}" ]]; then
    INIT_SESSION_TITLE="${topic} ($(date +%Y-%m-%d))"
    base_slug="$(slugify_ascii "$topic")"
    if [[ -z "${base_slug//[[:space:]]/}" ]]; then
      base_slug="session"
    fi
    INIT_SESSION_NAME="${base_slug}-$(date +%Y%m%d-%H%M%S)"
    INIT_SESSION_NAME="$(chats_db_unique_name "$INIT_SESSION_NAME")"
  else
    INIT_SESSION_TITLE="Specialist session ($(date +%Y-%m-%d))"
    INIT_SESSION_NAME="$(chats_db_unique_name "session-$(date +%Y%m%d-%H%M%S)")"
  fi
fi

if [[ -n "${LOOP_INIT//[[:space:]]/}" ]]; then
  chats_db_loop_init "$LOOP_INIT"
  exit 0
fi

if [[ $LOOP_STATUS -eq 1 ]]; then
  chats_db_loop_status
  exit 0
fi

if [[ $LOOP_INC -eq 1 ]]; then
  chats_db_loop_inc
  exit 0
fi

if [[ $LOOP_CLEAR -eq 1 ]]; then
  chats_db_loop_clear
  exit 0
fi

if [[ -n "${DELETE_CHAT_NAME//[[:space:]]/}" ]]; then
  chats_db_delete "$DELETE_CHAT_NAME"
  exit 0
fi

if [[ -n "${USE_CHAT_NAME//[[:space:]]/}" ]]; then
  resolved="$(chats_db_read | python3 -c '
import json,sys,re
name=sys.argv[1]
try:
    db=json.load(sys.stdin)
except Exception:
    sys.exit(0)
chats=(db.get("chats") or {})
names=sorted(chats.keys())
if name.isdigit():
    idx=int(name)
    if 1 <= idx <= len(names):
        name=names[idx-1]
c=(chats.get(name) or {})
u=c.get("url","")
if u and re.match(r"^https://chatgpt\.com/c/[0-9a-fA-F-]{16,}$", u):
    print(name + "\t" + u)
' "$USE_CHAT_NAME")"
  resolved_name="${resolved%%$'\t'*}"
  url="${resolved#*$'\t'}"
  if [[ -z "${url:-}" ]]; then
    echo "Unknown chat name: $USE_CHAT_NAME" >&2
    exit 2
  fi
  if [[ -n "${PROTECT_CHAT_URL//[[:space:]]/}" ]] && is_chat_conversation_url "${PROTECT_CHAT_URL}" \
    && [[ "$url" != "${PROTECT_CHAT_URL}" ]]; then
    emit_protect_chat_mismatch "${PROTECT_CHAT_URL}" "$url"
  fi
  chats_db_set_active "$resolved_name" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$CHATGPT_URL_FILE")" >/dev/null 2>&1 || true
  printf '%s\n' "$url" >"$CHATGPT_URL_FILE"
  write_work_chat_url "$url"
  echo "Using chat: $resolved_name" >&2
  exit 0
fi
}
