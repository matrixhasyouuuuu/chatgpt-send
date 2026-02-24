# shellcheck shell=bash
# Early command handlers (list/doctor/sessions/control) for chatgpt_send.

chatgpt_send_status_command() {
  local ops_tmp latest_run
  ops_tmp="$(mktemp)"
  if [[ -x "$ROOT/bin/ops_snapshot" ]]; then
    CHATGPT_SEND_CDP_PORT="$CDP_PORT" CHATGPT_SEND_STRICT_SINGLE_CHAT="$STRICT_SINGLE_CHAT" \
      "$ROOT/bin/ops_snapshot" --json >"$ops_tmp" 2>/dev/null || printf '%s\n' '{}' >"$ops_tmp"
  else
    printf '%s\n' '{}' >"$ops_tmp"
  fi
  latest_run="$(latest_run_dir | head -n 1 || true)"
  python3 - "$ROOT" "$ops_tmp" "${latest_run:-}" "${OUTPUT_JSON:-0}" <<'PY'
import json
import os
import pathlib
import re
import sys
import time
import datetime

root = pathlib.Path(sys.argv[1])
ops_path = pathlib.Path(sys.argv[2])
latest_run = pathlib.Path(sys.argv[3]) if sys.argv[3] else None
json_mode = int(sys.argv[4] or 0)

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="ignore").strip()
    except Exception:
        return ""

def path_mtime(path):
    try:
        return int(path.stat().st_mtime)
    except Exception:
        return None

def detect_swarm_snapshot(root_path: pathlib.Path, now_ts: int):
    runs_root = root_path / "state" / "runs"
    if not runs_root.exists():
        return {
            "present": False,
            "reason": "runs_root_missing",
        }
    candidates = []
    for d in runs_root.iterdir():
        if not d.is_dir():
            continue
        if not d.name.startswith("pool-"):
            continue
        summary_path = d / "fleet.summary.json"
        if not summary_path.exists():
            continue
        active_marker = d / ".pool.active"
        candidates.append({
            "dir": d,
            "summary_path": summary_path,
            "active": active_marker.exists(),
            "mtime": path_mtime(summary_path) or 0,
        })
    if not candidates:
        return {
            "present": False,
            "reason": "no_pool_runs",
        }

    active_candidates = [c for c in candidates if c["active"]]
    if active_candidates:
        active_candidates.sort(key=lambda x: x["mtime"], reverse=True)
        chosen = active_candidates[0]
        mode = "active"
        extra_active = max(0, len(active_candidates) - 1)
    else:
        candidates.sort(key=lambda x: x["mtime"], reverse=True)
        chosen = candidates[0]
        mode = "latest"
        extra_active = 0

    d = chosen["dir"]
    summary_path = chosen["summary_path"]
    heartbeat_path = d / "fleet.heartbeat"
    monitor_log_path = d / "fleet.monitor.log"
    summary = read_json(summary_path)
    if not isinstance(summary, dict) or not summary:
        return {
            "present": False,
            "reason": "fleet_summary_unreadable",
            "pool_run_dir": str(d),
            "fleet_summary_json": str(summary_path),
        }

    hb_text = read_text(heartbeat_path)
    hb_ts_ms = None
    m = re.search(r"ts_ms=(\d+)", hb_text or "")
    if m:
        try:
            hb_ts_ms = int(m.group(1))
        except Exception:
            hb_ts_ms = None
    heartbeat_age_sec = None
    if hb_ts_ms is not None:
        heartbeat_age_sec = max(0, now_ts - (hb_ts_ms // 1000))
    heartbeat_file_age_sec = None
    hb_mtime = path_mtime(heartbeat_path)
    if hb_mtime is not None:
        heartbeat_file_age_sec = max(0, now_ts - hb_mtime)

    summary_age_sec = None
    sm_mtime = path_mtime(summary_path)
    if sm_mtime is not None:
        summary_age_sec = max(0, now_ts - sm_mtime)

    monitor_log_age_sec = None
    ml_mtime = path_mtime(monitor_log_path)
    if ml_mtime is not None:
        monitor_log_age_sec = max(0, now_ts - ml_mtime)

    running = int(summary.get("running") or 0)
    pending = int(summary.get("pending") or 0)
    done = int(summary.get("done") or 0)
    failed = int(summary.get("failed") or 0)

    freshness_state = "unknown"
    freshness_reason = "no_heartbeat"
    if running > 0 or pending > 0:
        age_for_live = heartbeat_age_sec if heartbeat_age_sec is not None else heartbeat_file_age_sec
        if age_for_live is None:
            freshness_state = "unknown"
            freshness_reason = "heartbeat_missing"
        elif age_for_live <= 30:
            freshness_state = "fresh"
            freshness_reason = "heartbeat_recent"
        else:
            freshness_state = "stale"
            freshness_reason = "heartbeat_old"
    else:
        freshness_state = "fresh"
        freshness_reason = "completed_snapshot"

    agents = summary.get("agents") if isinstance(summary.get("agents"), list) else []
    agent_rows = []
    for row in agents:
        if not isinstance(row, dict):
            continue
        agent_rows.append({
            "agent_id": str(row.get("agent_id") or row.get("key") or "agent"),
            "state_class": str(row.get("state_class") or row.get("state") or "UNKNOWN"),
            "reason": str(row.get("reason") or ""),
            "last_step": str(row.get("last_step") or ""),
            "age_sec": row.get("age_sec"),
            "chat_proof": str(row.get("chat_proof") or "unknown"),
        })
    interesting = [r for r in agent_rows if r["state_class"] not in ("DONE_OK",)]
    if not interesting:
        interesting = agent_rows[:]
    interesting.sort(key=lambda r: (r["state_class"], str(r.get("agent_id"))))

    return {
        "present": True,
        "mode": mode,
        "pool_run_dir": str(d),
        "pool_run_id": d.name,
        "active_marker": bool(chosen["active"]),
        "multiple_active_markers": int(extra_active),
        "fleet_summary_json": str(summary_path),
        "fleet_heartbeat_file": str(heartbeat_path),
        "fleet_monitor_log": str(monitor_log_path),
        "summary": {
            "total": int(summary.get("total") or 0),
            "running": running,
            "pending": pending,
            "done": done,
            "failed": failed,
            "done_ok": int(summary.get("done_ok") or 0),
            "done_fail": int(summary.get("done_fail") or 0),
            "stuck": int(summary.get("stuck") or 0),
            "orphaned": int(summary.get("orphaned") or 0),
            "unknown": int(summary.get("unknown") or 0),
        },
        "freshness": {
            "state": freshness_state,
            "reason": freshness_reason,
            "heartbeat_age_sec": heartbeat_age_sec,
            "heartbeat_file_age_sec": heartbeat_file_age_sec,
            "summary_age_sec": summary_age_sec,
            "monitor_log_age_sec": monitor_log_age_sec,
        },
        "agents_preview": interesting[:12],
    }

ops = read_json(ops_path)
state = root / "state"
checkpoint = read_json(state / "last_specialist_checkpoint.json")

latest = {
    "exists": 0,
    "run_dir": "",
    "run_id": "",
    "summary_exists": 0,
    "manifest_exists": 0,
    "evidence_dir": "",
    "reason": "",
    "outcome": "",
    "exit_status": None,
    "ts_end": None,
}
if latest_run and latest_run.exists():
    latest["exists"] = 1
    latest["run_dir"] = str(latest_run)
    latest["run_id"] = latest_run.name
    man = read_json(latest_run / "manifest.json")
    summ = read_json(latest_run / "summary.json")
    contract = read_json(latest_run / "evidence" / "contract.json")
    probe = read_json(latest_run / "evidence" / "probe_last.json")
    fetch_last = read_json(latest_run / "evidence" / "fetch_last.json")
    latest["manifest_exists"] = int(bool(man))
    latest["summary_exists"] = int(bool(summ))
    latest["evidence_dir"] = str(latest_run / "evidence") if (latest_run / "evidence").exists() else ""
    latest["outcome"] = str(summ.get("outcome") or "").strip()
    try:
        latest["exit_status"] = int(summ["exit_status"]) if "exit_status" in summ else None
    except Exception:
        latest["exit_status"] = None
    try:
        latest["ts_end"] = int(summ["ts_end"]) if "ts_end" in summ else None
    except Exception:
        latest["ts_end"] = None
    reason = ""
    for cand in (
        probe.get("reason"),
        contract.get("reason"),
        summ.get("outcome"),
    ):
        s = str(cand or "").strip()
        if not s:
            continue
        reason = s
        if s.startswith("E_"):
            break
    latest["reason"] = reason
    latest["reply_pending_streaming"] = int(
        bool(fetch_last)
        and bool(fetch_last.get("stop_visible"))
        and not bool(fetch_last.get("assistant_after_last_user"))
        and str(reason or "").startswith("E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE")
    )

blockers = []
warnings = []
next_actions = []

target_chat_id = str(ops.get("target_chat_id") or "").strip()
cdp_ok = int(ops.get("cdp_ok") or 0)
route_ok = int(ops.get("chat_route_ok") or 0)
strict_single_chat = int(ops.get("strict_single_chat") or 0)
tab_count = int(ops.get("tab_count") or 0)
pending_unacked = int(((ops.get("pending_details") or {}).get("pending_unacked")) or 0)
ledger_state = str(((ops.get("ledger_last") or {}).get("state")) or "").strip()

if not target_chat_id:
    blockers.append("no_target_chat")
    next_actions.append("Выберите/синхронизируйте чат (`--use-chat` или `--sync-chatgpt-url`).")
if cdp_ok != 1:
    blockers.append("cdp_down")
    next_actions.append("Поднимите браузер (`--open-browser`) или выполните `--graceful-restart-browser`.")
if cdp_ok == 1 and target_chat_id and route_ok != 1:
    blockers.append("route_mismatch")
    next_actions.append("Проверьте активную вкладку ChatGPT и синхронизируйте URL (`--sync-chatgpt-url`).")
if strict_single_chat == 1 and tab_count > 1:
    if cdp_ok == 1 and target_chat_id and route_ok == 1:
        warnings.append("multiple_chat_tabs")
        next_actions.append("Обнаружены лишние `/c/...` вкладки ChatGPT: это warning (route OK), но лучше закрыть лишние вкладки.")
    else:
        blockers.append("multiple_chat_tabs")
        next_actions.append("Закройте лишние `/c/...` вкладки ChatGPT или включите auto-cleanup policy.")
if pending_unacked == 1:
    blockers.append("reply_unacked")
    next_actions.append("Сначала подтвердите прочтение последнего ответа (`--ack`).")
if ledger_state == "pending" and pending_unacked == 0:
    warnings.append("ledger_pending")
    next_actions.append("Есть незавершенный цикл SEND->REPLY; сначала проверьте ответ/состояние чата.")

if latest["exists"] and latest.get("reason", "").startswith("E_"):
    warnings.append("latest_run_failed")
if int(latest.get("reply_pending_streaming") or 0) == 1:
    warnings.append("reply_pending_streaming")
    next_actions.append("Specialist еще печатает ответ: дождаться завершения и сделать read-only fetch/status без resend.")

seen = set()
dedup_next = []
for item in next_actions:
    if item not in seen:
        dedup_next.append(item)
        seen.add(item)
next_actions = dedup_next

status = "ready"
if blockers:
    status = "blocked"
elif warnings:
    status = "degraded"

multi_tabs_present = bool(tab_count > 1)
if not multi_tabs_present:
    multi_tabs = {
        "present": False,
        "tab_count": int(tab_count),
        "severity": "none",
        "reason": "",
        "hint": "",
    }
elif "multiple_chat_tabs" in blockers:
    multi_tabs = {
        "present": True,
        "tab_count": int(tab_count),
        "severity": "block",
        "reason": "route_uncertain_multiple_tabs",
        "hint": "Несколько ChatGPT `/c/...` вкладок и routing не подтвержден однозначно; сначала устраните неоднозначность.",
    }
else:
    multi_tabs = {
        "present": True,
        "tab_count": int(tab_count),
        "severity": "warning",
        "reason": "route_ok_multiple_tabs",
        "hint": "Есть лишние ChatGPT `/c/...` вкладки: route OK, но лучше закрыть лишние для стабильности.",
    }

obj = {
    "schema_version": "status.v1",
    "ts": int(time.time()),
    "status": status,
    "can_send": int(len(blockers) == 0),
    "blockers": blockers,
    "warnings": warnings,
    "next_actions": next_actions,
    "multi_tabs": multi_tabs,
    "ops": ops,
    "checkpoint": checkpoint if isinstance(checkpoint, dict) else {},
    "latest_run": latest,
    "swarm": detect_swarm_snapshot(root, int(time.time())),
}

operator_state = "READY"
operator_why = "ok_ready"
operator_next = "STEP_READ"
operator_note = "Состояние готово к следующему безопасному шагу (сначала `step read`)."
operator_confidence = "high"

if cdp_ok != 1:
    operator_state = "ERROR"
    operator_why = "cdp_unreachable"
    operator_next = "RUN_EXPLAIN"
    operator_note = "CDP/браузер недоступен: сначала восстановить окружение."
    operator_confidence = "low"
elif "reply_unacked" in blockers:
    operator_state = "BLOCKED"
    operator_why = "ack_required"
    operator_next = "ACK"
    operator_note = "Есть непрочитанный ответ Specialist; подтвердите `--ack`."
elif "no_target_chat" in blockers:
    operator_state = "BLOCKED"
    operator_why = "no_target_chat"
    operator_next = "RUN_STATUS"
    operator_note = "Не выбран work chat; сначала синхронизируйте/выберите чат."
elif "route_mismatch" in blockers:
    operator_state = "BLOCKED"
    operator_why = "routing_blocked"
    operator_next = "RUN_STATUS"
    operator_note = "Routing не подтвержден; сначала восстановите правильную вкладку чата."
    operator_confidence = "med"
elif "multiple_chat_tabs" in blockers:
    operator_state = "BLOCKED"
    operator_why = "multi_tabs_blocked"
    operator_next = "RUN_STATUS"
    operator_note = "Несколько вкладок ChatGPT делают routing небезопасным."
    operator_confidence = "med"
elif "ledger_pending" in warnings:
    operator_state = "WAITING"
    operator_why = "pending_cycle"
    operator_next = "STEP_WAIT_FINISHED"
    operator_note = "Предыдущий цикл SEND->REPLY еще не завершен; дождитесь/дочитайте ответ."
    operator_confidence = "med"
elif "reply_pending_streaming" in warnings:
    operator_state = "WAITING"
    operator_why = "reply_pending_streaming"
    operator_next = "STEP_WAIT_FINISHED"
    operator_note = "UI показывает активную генерацию ответа Specialist; дождитесь завершения и читайте read-only без resend."
    operator_confidence = "high"
elif "latest_run_failed" in warnings:
    operator_state = "RECOVERABLE"
    operator_why = "latest_run_failed"
    operator_next = "RUN_EXPLAIN"
    operator_note = "Последний запуск завершился с ошибкой; сначала посмотрите explain/latest."
    operator_confidence = "med"
elif "multiple_chat_tabs" in warnings:
    operator_state = "READY"
    operator_why = "multi_tabs_warning"
    operator_next = "STEP_READ"
    operator_note = "Route OK, но есть лишние вкладки ChatGPT (warning)."
    operator_confidence = "med"

obj["operator_summary"] = {
    "state": operator_state,
    "why": operator_why,
    "next": operator_next,
    "note": operator_note,
    "confidence": operator_confidence,
}

swarm = obj.get("swarm") or {}
if isinstance(swarm, dict) and swarm.get("present"):
    swarm_fresh = ((swarm.get("freshness") or {}).get("state") or "").strip()
    swarm_summary = (swarm.get("summary") or {}) if isinstance(swarm.get("summary"), dict) else {}
    if swarm_fresh == "stale" and int(swarm_summary.get("running") or 0) > 0:
        if "swarm_status_stale" not in warnings:
            warnings.append("swarm_status_stale")
        next_actions.append("Сводка роя устарела (heartbeat старый): проверить monitor/fleet follow перед решениями по рою.")
        if status == "ready":
            status = "degraded"

if json_mode == 1:
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
    raise SystemExit(0)

print(f"STATUS {status} can_send={obj['can_send']} blockers={len(blockers)} warnings={len(warnings)}")
print(f"  chat: {target_chat_id or 'none'}")
print(f"  cdp: {'OK' if cdp_ok == 1 else 'DOWN'}  route: {'OK' if route_ok == 1 else 'MISMATCH'}  tabs={tab_count}")
print(f"  multi_tabs: {multi_tabs['severity']} present={1 if multi_tabs['present'] else 0}")
print(f"  unacked_reply: {pending_unacked}  ledger: {ledger_state or 'none'}")
ckpt_id = str((checkpoint or {}).get('checkpoint_id') or '').strip()
ckpt_ts = str((checkpoint or {}).get('ts') or '').strip()
print(f"  checkpoint: {ckpt_id or 'none'}  ts={ckpt_ts or 'none'}")
if latest["exists"]:
    print(f"  latest_run: {latest['run_id']} reason={latest.get('reason') or 'none'} outcome={latest.get('outcome') or 'none'}")
swarm = obj.get("swarm") or {}
if isinstance(swarm, dict) and swarm.get("present"):
    ssum = (swarm.get("summary") or {}) if isinstance(swarm.get("summary"), dict) else {}
    sf = (swarm.get("freshness") or {}) if isinstance(swarm.get("freshness"), dict) else {}
    print(
        "  swarm: "
        f"{swarm.get('pool_run_id') or 'pool'} "
        f"mode={swarm.get('mode') or 'unknown'} "
        f"freshness={sf.get('state') or 'unknown'} "
        f"(hb_age={sf.get('heartbeat_age_sec') if sf.get('heartbeat_age_sec') is not None else 'none'}s, "
        f"summary_age={sf.get('summary_age_sec') if sf.get('summary_age_sec') is not None else 'none'}s) "
        f"total={ssum.get('total', 0)} run={ssum.get('running', 0)} done={ssum.get('done', 0)} fail={ssum.get('failed', 0)} pending={ssum.get('pending', 0)}"
    )
    for row in (swarm.get("agents_preview") or []):
        if not isinstance(row, dict):
            continue
        rid = str(row.get("agent_id") or "agent")
        cls = str(row.get("state_class") or "UNKNOWN")
        age = row.get("age_sec")
        age_s = f"{age}s" if isinstance(age, int) else "?"
        reason = str(row.get("last_step") or row.get("reason") or "").strip()
        if len(reason) > 100:
            reason = reason[:97] + "..."
        print(f"  swarm_agent: {rid} {cls} age={age_s} proof={row.get('chat_proof') or 'unknown'} {reason}")
elif isinstance(swarm, dict) and swarm.get("reason"):
    print(f"  swarm: none ({swarm.get('reason')})")
for b in blockers:
    print(f"BLOCKER {b}")
for w in warnings:
    print(f"WARN {w}")
if int(latest.get("reply_pending_streaming") or 0) == 1:
    print("INFO reply_pending_streaming=1 stop_visible=1 assistant_after_last_user=0")
for step in next_actions:
    print(f"NEXT {step}")
PY
  st=$?
  rm -f "$ops_tmp" >/dev/null 2>&1 || true
  return "$st"
}

chatgpt_send_explain_command() {
  python3 - "$ROOT" "${EXPLAIN_TARGET:-latest}" "${OUTPUT_JSON:-0}" <<'PY'
import json
import pathlib
import re
import sys
import time

root = pathlib.Path(sys.argv[1])
raw_target = (sys.argv[2] or "latest").strip() or "latest"
json_mode = int(sys.argv[3] or 0)

sys.path.insert(0, str(root))
try:
    from ux.error_registry import resolve_error_spec as _resolve_error_spec  # type: ignore
    from ux.error_registry import resolve_error_spec_with_meta as _resolve_error_spec_with_meta  # type: ignore
except Exception:
    _resolve_error_spec = None
    _resolve_error_spec_with_meta = None

def resolve_error_spec_local(code):
    if not _resolve_error_spec:
        return None
    try:
        return _resolve_error_spec(code)
    except Exception:
        return None

def resolve_error_spec_meta_local(code):
    if _resolve_error_spec_with_meta:
        try:
            meta = _resolve_error_spec_with_meta(code)
            if isinstance(meta, dict):
                return meta
        except Exception:
            pass
    spec = resolve_error_spec_local(code)
    if spec is None:
        return None
    return {"spec": spec, "match_kind": "registry"}

def spec_to_obj(spec):
    if not spec:
        return None
    return {
        "code": str(getattr(spec, "code", "") or ""),
        "class": str(getattr(spec, "cls", "") or ""),
        "block": str(getattr(spec, "block", "") or ""),
        "title": str(getattr(spec, "title", "") or ""),
        "why": str(getattr(spec, "why", "") or ""),
        "recommended": list(getattr(spec, "recommended", ()) or ()),
        "safe_to_autostep": bool(getattr(spec, "safe_to_autostep", False)),
        "evidence_keys": list(getattr(spec, "evidence_keys", ()) or ()),
        "tags": list(getattr(spec, "tags", ()) or ()),
    }

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

def map_error(code, ctx=None):
    ctx = ctx or {}
    code = str(code or "").strip()
    code_norm = re.sub(r"[^A-Z0-9_]", "_", code.upper())
    ui = ctx.get("fetch_last") or {}
    ui_diag = (ui.get("ui_diag") or {}) if isinstance(ui, dict) else {}
    stop_visible = bool(ui.get("stop_visible"))
    assistant_after_last_user = bool(ui.get("assistant_after_last_user"))
    total_messages = int(ui.get("total_messages") or 0) if isinstance(ui, dict) else 0
    login = bool(ui_diag.get("login_detected"))
    captcha = bool(ui_diag.get("captcha_detected"))
    offline = bool(ui_diag.get("offline_detected"))

    summary_ctx = ctx.get("summary") or {}
    ops_ctx = ctx.get("ops") or {}
    last_ev = (ops_ctx.get("last_protocol_event") or {}) if isinstance(ops_ctx, dict) else {}
    last_ev_meta = str(last_ev.get("meta") or "")

    mapping = {
        "E_REPLY_UNACKED_BLOCK_SEND": (
            "Отправка заблокирована: есть непрочитанный (не `ack`) ответ Specialist.",
            ["Пайплайн остановил отправку до повторного send."],
            ["Выполнить `chatgpt_send --ack` после чтения ответа.", "Повторить действие без изменения чата."]
        ),
        "E_NO_BLIND_RESEND_PROMPT_ALREADY_PRESENT": (
            "Обнаружен риск слепого повторного send для уже присутствующего prompt.",
            ["Пайплайн не отправил дубль и снял evidence."],
            ["Сначала прочитать/восстановить ответ (`fetch-last`/`read-only`).", "Только затем решать, нужен ли resend."]
        ),
        "E_MULTIPLE_CHAT_TABS_BLOCKED": (
            "Strict single chat заблокировал работу: открыто несколько `/c/...` вкладок.",
            ["Ничего не отправлено; защита от работы не в том чате сохранена."],
            ["Закрыть лишние вкладки ChatGPT `/c/...`.", "Либо переключить policy на auto-close (если это допустимо)."]
        ),
        "E_SOFT_RESET_FAILED": (
            "Автовосстановление UI/CDP (soft reset) не завершилось успешно.",
            ["Снят evidence (контракт, tabs, fetch_last, ops snapshot)."],
            ["Проверить видимость и готовность вкладки ChatGPT.", "Запустить `chatgpt_send --graceful-restart-browser`.", "После восстановления сделать read-only проверку (`--status` / fetch-last)."]
        ),
        "E_CDP_UNREACHABLE": (
            "CDP недоступен: браузер не поднят или порт недоступен.",
            ["Операция остановлена до отправки."],
            ["Открыть/перезапустить браузер (`--open-browser` или `--graceful-restart-browser`)."]
        ),
        "E_LOGIN_REQUIRED": (
            "ChatGPT требует логин, автоматизация не может продолжить send/read.",
            ["Операция остановлена до отправки."],
            ["Войти в ChatGPT в видимом браузере и повторить действие."]
        ),
        "E_CLOUDFLARE": (
            "Появилась captcha/Cloudflare-защита.",
            ["Операция остановлена без resend."],
            ["Пройти challenge вручную в браузере и повторить read/send."]
        ),
        "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE": (
            "Ожидание ответа превысило лимит: UI показывал активную генерацию (`stop_visible`).",
            ["Пайплайн ждал ответ и сохранил evidence таймаута."],
            ["Сделать read-only fetch ответа без resend.", "При частых случаях увеличить `CHATGPT_SEND_REPLY_MAX_SEC`.", "Проверить, не завис ли UI ChatGPT."]
        ),
        "E_REPLY_WAIT_TIMEOUT_NO_ACTIVITY": (
            "Ожидание ответа превысило лимит без признаков прогресса.",
            ["Снят evidence таймаута и UI состояния."],
            ["Проверить вкладку/сеть/состояние UI.", "Повторить через read-only проверку, не отправляя дубль."]
        ),
        "E_SEND_RETRY_VETO_INTRA_RUN": (
            "Повторная отправка внутри того же run заблокирована (защита от дубля после timeout).",
            ["Пайплайн перешёл в confirm-only/no-resend режим вместо второго send."],
            ["Сделать `chatgpt_send --status --json` для refresh состояния.", "Сделать `chatgpt_send --explain latest --json` для деталей reason/stage.", "Если ответ уже появился, прочитать и выполнить `--ack`."]
        ),
        "E_PROMPT_NOT_CONFIRMED_NO_RESEND": (
            "После timeout система не смогла подтвердить доставку prompt и остановилась без resend (safety stop).",
            ["Повторная отправка была намеренно запрещена, чтобы не создать дубль."],
            ["Повторить read-only проверку (`--status` / fetch-last).", "Если prompt/ответ уже появились, продолжить без resend и подтвердить `--ack`.", "Если prompt точно не доставлен и состояние стабильно — запускать новый send."],
        ),
        "E_CONFIRM_FETCH_LAST_FAILED": (
            "Не удалось подтвердить состояние чата через fetch_last в confirm-only режиме (fail-closed).",
            ["Пайплайн остановился без resend, чтобы не отправить дубль при нестабильном UI/CDP."],
            ["Проверить `chatgpt_send --status` (CDP/route/tabs).", "Повторить read-only fetch после стабилизации UI/браузера.", "При необходимости перезапустить браузер/CDP и только потом повторять отправку."],
        ),
        "E_CDP_TIMEOUT_RETRY": (
            "Сработал recovery-путь после timeout (status4): система перешла к безопасной проверке вместо слепого resend.",
            ["Запущен timeout-retry recovery с защитой от дублей."],
            ["Посмотреть `--explain latest` для итога confirm-only ветки.", "Дальше следовать `status/step` подсказкам без ручного resend."],
        ),
    }
    what, auto, nxt = mapping.get(code_norm, (
        "Операция завершилась ошибкой/блокировкой.",
        ["Система остановила шаг и сохранила evidence (если был run)."],
        ["Открыть `chatgpt_send --status` и `chatgpt_send --explain latest` для контекста."]
    ))

    if login and "Войти в ChatGPT" not in " ".join(nxt):
        nxt.insert(0, "Войти в ChatGPT в браузере (обнаружен login screen).")
    if captcha and "challenge" not in " ".join(nxt).lower():
        nxt.insert(0, "Пройти captcha/Cloudflare challenge вручную.")
    if offline:
        nxt.insert(0, "Проверить сеть/доступ к chatgpt.com (обнаружен offline UI).")
    if stop_visible and total_messages == 0 and code_norm.startswith("E_"):
        auto.append("По evidence UI мог быть в промежуточном состоянии: `stop_visible` при пустом списке сообщений.")
    if code_norm == "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE" and stop_visible and not assistant_after_last_user:
        what = "Ответ Specialist еще допечатывается (`reply_pending_streaming`): UI показывает активную генерацию, но готовый ответ после последнего user еще не зафиксирован."
        auto.insert(0, "Система попала в промежуточное состояние streaming; это не означает потерю контекста.")
        nxt = [
            "Подождать завершения генерации и повторить read-only fetch/status без resend.",
            "Не отправлять новый prompt, пока не появится ответ после последнего user.",
            "При регулярных кейсах увеличить `CHATGPT_SEND_REPLY_MAX_SEC`/late-recovery grace."
        ] + list(nxt)
    if code_norm == "E_PROMPT_NOT_CONFIRMED_NO_RESEND" and total_messages == 0:
        auto.append("В момент confirm-fetch UI мог вернуть `messages=0` (transient UI/CDP состояние).")
    if code_norm == "E_SEND_RETRY_VETO_INTRA_RUN" and "prompt_present=1" in last_ev_meta:
        auto.insert(0, "Обнаружено, что prompt уже присутствует в чате; resend внутри run был остановлен.")
    if code_norm == "E_CDP_TIMEOUT_RETRY" and "decision=confirm_only" in last_ev_meta:
        auto.insert(0, "После timeout был выбран confirm-only/no-resend путь.")
    return what, auto, nxt

def normalize_run_error_code(run_outcome, summary_obj, ops_obj, probe_obj, contract_obj):
    run_outcome = str(run_outcome or "").strip()
    summary_reason = str((summary_obj or {}).get("reason") or "").strip()
    exit_status = int((summary_obj or {}).get("exit_status") or 0)
    last_ev = ((ops_obj or {}).get("last_protocol_event") or {}) if isinstance(ops_obj, dict) else {}
    last_action = str(last_ev.get("action") or "").strip()
    last_meta = str(last_ev.get("meta") or "")

    for cand in (summary_reason, str((probe_obj or {}).get("reason") or "").strip(), str((contract_obj or {}).get("reason") or "").strip()):
        if cand.startswith("E_"):
            if cand == "E_EXIT_81_send_retry_veto_intra_run_unconfirmed":
                return "E_PROMPT_NOT_CONFIRMED_NO_RESEND"
            return cand

    if "confirm_fetch_last_failed" in last_meta:
        return "E_CONFIRM_FETCH_LAST_FAILED"
    if "prompt_not_confirmed_no_resend" in last_meta:
        return "E_PROMPT_NOT_CONFIRMED_NO_RESEND"
    if last_action == "SEND_RETRY_VETO_INTRA_RUN":
        return "E_SEND_RETRY_VETO_INTRA_RUN"
    if "send_retry_veto_intra_run" in run_outcome:
        return "E_SEND_RETRY_VETO_INTRA_RUN"
    if "status4_timeout" in summary_reason or "status4_timeout" in last_meta:
        return "E_CDP_TIMEOUT_RETRY"
    if run_outcome.startswith("E_"):
        return run_outcome
    return ""

def detect_run_dir(target: str):
    p = pathlib.Path(target).expanduser()
    if target == "latest":
      runs_root = root / "state" / "runs"
      if not runs_root.exists():
          return None
      runs = sorted([x for x in runs_root.iterdir() if x.is_dir()], key=lambda x: x.stat().st_mtime, reverse=True)
      return runs[0] if runs else None
    if re.match(r"^E_[A-Z0-9_]+$", target):
      return None
    if p.exists():
      if p.is_file():
          for parent in [p.parent, p.parent.parent]:
              if (parent / "manifest.json").exists() or (parent / "summary.json").exists():
                  return parent
          return p.parent
      return p
    candidate = root / "state" / "runs" / target
    if candidate.exists():
      return candidate
    return None

target_kind = "error_code" if re.match(r"^E_[A-Z0-9_]+$", raw_target) else "run"
run_dir = detect_run_dir(raw_target)

obj = {
    "schema_version": "explain.v1",
    "ts": int(time.time()),
    "target": raw_target,
    "target_kind": target_kind,
    "run_dir": "",
    "run_id": "",
    "error_code": "",
    "error": None,
    "block_reason": "",
    "run_outcome": "",
    "what": "",
    "auto_actions": [],
    "next_actions": [],
    "evidence": [],
    "details": {},
}

if target_kind == "error_code" and run_dir is None:
    code = raw_target
    what, auto, nxt = map_error(code)
    obj["error_code"] = code
    obj["block_reason"] = "UNKNOWN_BLOCK"
    obj["what"] = what
    obj["auto_actions"] = auto
    obj["next_actions"] = nxt
else:
    if run_dir is None or not run_dir.exists():
        code = "E_EXPLAIN_TARGET_NOT_FOUND"
        obj["error_code"] = code
        obj["what"] = "Не найден target для explain."
        obj["next_actions"] = ["Передайте `latest`, `RUN_ID`, путь к run dir или код вида `E_*`."]
    else:
        run_dir = run_dir.resolve()
        obj["run_dir"] = str(run_dir)
        obj["run_id"] = run_dir.name
        manifest = read_json(run_dir / "manifest.json")
        summary = read_json(run_dir / "summary.json")
        contract = read_json(run_dir / "evidence" / "contract.json")
        probe = read_json(run_dir / "evidence" / "probe_last.json")
        fetch_last = read_json(run_dir / "evidence" / "fetch_last.json")
        ops = read_json(run_dir / "evidence" / "ops_snapshot.json")
        details = {
            "manifest": manifest,
            "summary": summary,
            "contract": contract,
            "probe_last": probe,
            "fetch_last": fetch_last,
            "ops_snapshot": ops,
        }
        obj["details"] = details
        run_outcome = str(summary.get("outcome") or "").strip()
        obj["run_outcome"] = run_outcome

        code = normalize_run_error_code(run_outcome, summary, ops, probe, contract)
        is_success = run_outcome.lower() in ("ok", "pass", "success") and int(summary.get("exit_status") or 0) == 0
        if is_success and not code:
            obj["error_code"] = ""
            obj["block_reason"] = "NO_BLOCK"
            what = "Последний запуск завершился успешно."
            auto = ["Пайплайн завершился без ошибки; summary/evidence сохранены."]
            nxt = ["Открыть `chatgpt_send --status` для текущего состояния.", "Продолжить следующий шаг (`step read/auto/send`) по контексту."]
        else:
            if not code:
                code = run_outcome or "E_UNKNOWN"
            obj["error_code"] = code
            obj["block_reason"] = "UNKNOWN_BLOCK"
            what, auto, nxt = map_error(code, {"fetch_last": fetch_last, "ops": ops, "summary": summary})

        ui_diag = (fetch_last.get("ui_diag") or {}) if isinstance(fetch_last, dict) else {}
        if fetch_last:
            obj["evidence"].append({"file": str(run_dir / "evidence" / "fetch_last.json"), "hint": f"ui_state={fetch_last.get('ui_state') or 'none'} stop_visible={int(bool(fetch_last.get('stop_visible')))} total_messages={int(fetch_last.get('total_messages') or 0)}"})
        if contract:
            obj["evidence"].append({"file": str(run_dir / "evidence" / "contract.json"), "hint": f"status={contract.get('status')} reason={(contract.get('reason') or 'none')}"})
        if probe:
            obj["evidence"].append({"file": str(run_dir / "evidence" / "probe_last.json"), "hint": f"reason={(probe.get('reason') or 'none')} stop_visible={probe.get('stop_visible')}"})
        if summary:
            obj["evidence"].append({"file": str(run_dir / "summary.json"), "hint": f"outcome={(summary.get('outcome') or 'none')} exit_status={summary.get('exit_status')}"})
        if manifest:
            obj["evidence"].append({"file": str(run_dir / "manifest.json"), "hint": f"chat_url={(manifest.get('chat_url') or '')[:64]}"})

        if bool(ui_diag.get("login_detected")):
            nxt.insert(0, "UI показывает login screen: войти вручную в ChatGPT.")
        if bool(ui_diag.get("captcha_detected")):
            nxt.insert(0, "UI показывает captcha/Cloudflare: пройти challenge вручную.")
        if bool(ui_diag.get("offline_detected")):
            nxt.insert(0, "UI показывает offline/error banner: проверить сеть.")
        if int((ops.get("cdp_ok") or 0)) == 0:
            nxt.insert(0, "CDP недоступен в evidence: сначала поднять/перезапустить браузер.")
        if int((ops.get("pending_details") or {}).get("pending_unacked") or 0) == 1:
            nxt.insert(0, "В evidence есть непрочитанный ответ: подтвердить `--ack` после чтения.")

        seen = set()
        auto = [x for x in auto if not (x in seen or seen.add(x))]
        seen = set()
        nxt = [x for x in nxt if not (x in seen or seen.add(x))]
        obj["what"] = what
        obj["auto_actions"] = auto
        obj["next_actions"] = nxt

spec_meta = resolve_error_spec_meta_local(obj.get("error_code"))
spec = (spec_meta or {}).get("spec")
resolver_kind = str((spec_meta or {}).get("match_kind") or "")
spec_obj = spec_to_obj(spec)
if spec_obj:
    obj["error_spec"] = spec_obj
    obj["error_class"] = spec_obj.get("class") or ""
    obj["block_reason"] = spec_obj.get("block") or (obj.get("block_reason") or "")
    obj["error"] = {
        "code": obj.get("error_code") or "",
        "class": spec_obj.get("class") or "",
        "block": spec_obj.get("block") or "",
        "title": spec_obj.get("title") or "",
        "why": spec_obj.get("why") or "",
        "resolver": resolver_kind or "registry",
    }
    generic_prefixes = (
        "Операция завершилась ошибкой",
        "Операция завершилась",
    )
    if (not obj.get("what")) or any(str(obj.get("what") or "").startswith(p) for p in generic_prefixes):
        title = spec_obj.get("title") or ""
        why = spec_obj.get("why") or ""
        obj["what"] = (title + (". " + why if why else "")).strip() or (obj.get("what") or "")
    merged = []
    for item in (spec_obj.get("recommended") or []) + (obj.get("next_actions") or []):
        if item and item not in merged:
            merged.append(item)
    obj["next_actions"] = merged
else:
    obj["error_class"] = ""
    if obj.get("error_code"):
        obj["error"] = {
            "code": obj.get("error_code") or "",
            "class": "",
            "block": obj.get("block_reason") or "",
            "title": "",
            "why": "",
            "resolver": resolver_kind or "",
        }
    elif not obj.get("block_reason"):
        obj["block_reason"] = "NO_BLOCK"

def _operator_state_from_explain(block_reason, error_class, has_error):
    br = str(block_reason or "")
    ec = str(error_class or "")
    if not has_error and br in ("", "NO_BLOCK"):
        return "READY"
    if br == "SOFT_BLOCK_WAIT":
        return "WAITING"
    if br in ("SOFT_BLOCK_RECOVER", "SOFT_BLOCK_RETRYABLE"):
        return "RECOVERABLE"
    if ec in ("ENV", "CDP", "BROWSER"):
        return "ERROR"
    if br == "HARD_BLOCK_ENV":
        return "ERROR"
    return "BLOCKED"

def _operator_next_from_explain(obj):
    es = obj.get("error_spec") or {}
    rec = es.get("recommended") or []
    if rec:
        return str(rec[0])
    code = str(obj.get("error_code") or "")
    br = str(obj.get("block_reason") or "")
    if code in ("E_REPLY_UNACKED_BLOCK_SEND", "E_ACK_REQUIRED"):
        return "ACK"
    if br == "SOFT_BLOCK_WAIT":
        return "STEP_WAIT_FINISHED"
    if br in ("SOFT_BLOCK_RECOVER", "SOFT_BLOCK_RETRYABLE"):
        return "STEP_PREFLIGHT"
    if br in ("", "NO_BLOCK"):
        return "RUN_STATUS"
    return "RUN_EXPLAIN"

explain_state = _operator_state_from_explain(obj.get("block_reason"), obj.get("error_class"), bool(obj.get("error_code")))
fetch_last_obj = (obj.get("details") or {}).get("fetch_last") or {}
if (
    str(obj.get("error_code") or "") == "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE"
    and isinstance(fetch_last_obj, dict)
    and bool(fetch_last_obj.get("stop_visible"))
    and not bool(fetch_last_obj.get("assistant_after_last_user"))
):
    explain_state = "WAITING"
explain_why = str(obj.get("error_code") or "").strip()
if explain_why:
    explain_why = explain_why.lower()
    if explain_why.startswith("e_"):
        explain_why = explain_why[2:]
else:
    br = str(obj.get("block_reason") or "").strip()
    explain_why = (br.lower() if br and br != "NO_BLOCK" else "ok")
if explain_why == "e_prefight_stale":
    explain_why = "stale_preflight"
if explain_why == "e_preflight_stale":
    explain_why = "stale_preflight"
if (
    str(obj.get("error_code") or "") == "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE"
    and isinstance(fetch_last_obj, dict)
    and bool(fetch_last_obj.get("stop_visible"))
    and not bool(fetch_last_obj.get("assistant_after_last_user"))
):
    explain_why = "reply_pending_streaming"
explain_next = _operator_next_from_explain(obj)
if explain_why == "reply_pending_streaming":
    explain_next = "STEP_WAIT_FINISHED"
explain_note = str(obj.get("what") or "").strip() or "Нет данных для explain."
explain_confidence = "high" if obj.get("error_spec") else ("med" if obj.get("error_code") else "low")
if str(obj.get("error_code") or "") == "E_EXPLAIN_TARGET_NOT_FOUND":
    explain_confidence = "low"
obj["operator_summary"] = {
    "state": explain_state,
    "why": explain_why,
    "next": explain_next,
    "note": explain_note,
    "confidence": explain_confidence,
}

if json_mode == 1:
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
    raise SystemExit(0)

print(f"EXPLAIN target={obj['target']} code={obj.get('error_code') or 'none'}")
if obj.get("run_id"):
    print(f"  run_id: {obj['run_id']}")
    print(f"  run_dir: {obj['run_dir']}")
if obj.get("block_reason"):
    print(f"  block: {obj.get('block_reason')}")
if obj.get("error_spec"):
    es = obj["error_spec"]
    print(f"  class: {es.get('class') or 'none'}  block: {es.get('block') or 'none'}")
print(f"WHAT {obj.get('what') or 'Нет данных'}")
for item in obj.get("auto_actions") or []:
    print(f"AUTO {item}")
for item in obj.get("next_actions") or []:
    print(f"NEXT {item}")
for ev in obj.get("evidence") or []:
    print(f"EVIDENCE {ev.get('file')} :: {ev.get('hint')}")
PY
}

chatgpt_send_step_emit_plan() {
  local status_json="$1"
  local mode="${2:-read}"
  local message="${3:-}"
  python3 - "$ROOT" "$status_json" "$mode" "$message" "$RUN_ID" "$CHATGPT_SEND_TRANSPORT" "$STEP_MAX_STEPS" "$ROOT/state/status/preflight_token.v1.json" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time
import datetime

root = pathlib.Path(sys.argv[1])
status_path = pathlib.Path(sys.argv[2])
mode = (sys.argv[3] or "read").strip() or "read"
message = sys.argv[4] or ""
run_id = sys.argv[5] or ""
transport = (sys.argv[6] or "cdp").strip() or "cdp"
max_steps = sys.argv[7] or "1"
preflight_token_path = pathlib.Path(sys.argv[8])

sys.path.insert(0, str(root))
try:
    from ux.error_registry import resolve_error_spec as _resolve_error_spec  # type: ignore
    from ux.error_registry import resolve_error_spec_with_meta as _resolve_error_spec_with_meta  # type: ignore
except Exception:
    _resolve_error_spec = None
    _resolve_error_spec_with_meta = None

def resolve_error_spec_local(code):
    if not _resolve_error_spec:
        return None
    try:
        return _resolve_error_spec(code)
    except Exception:
        return None

def resolve_error_spec_meta_local(code):
    if _resolve_error_spec_with_meta:
        try:
            meta = _resolve_error_spec_with_meta(code)
            if isinstance(meta, dict):
                return meta
        except Exception:
            pass
    spec = resolve_error_spec_local(code)
    if spec is None:
        return None
    return {"spec": spec, "match_kind": "registry"}

def spec_to_obj(spec):
    if not spec:
        return None
    return {
        "code": str(getattr(spec, "code", "") or ""),
        "class": str(getattr(spec, "cls", "") or ""),
        "block": str(getattr(spec, "block", "") or ""),
        "title": str(getattr(spec, "title", "") or ""),
        "why": str(getattr(spec, "why", "") or ""),
        "recommended": list(getattr(spec, "recommended", ()) or ()),
        "safe_to_autostep": bool(getattr(spec, "safe_to_autostep", False)),
        "evidence_keys": list(getattr(spec, "evidence_keys", ()) or ()),
        "tags": list(getattr(spec, "tags", ()) or ()),
    }

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

def parse_int(v, default=0):
    try:
        return int(v)
    except Exception:
        return default

def env_int(name: str, default: int, min_v: int | None = None, max_v: int | None = None) -> int:
    val = parse_int(os.environ.get(name), default)
    if min_v is not None and val < min_v:
        val = min_v
    if max_v is not None and val > max_v:
        val = max_v
    return val

def build_preflight_state(root_path: pathlib.Path, token_path: pathlib.Path, st_obj: dict, ops_obj: dict, checkpoint_obj: dict) -> dict:
    now_ts = int(time.time())
    ttl_sec = env_int("CHATGPT_SEND_PREFLIGHT_TTL_SEC", 8, 1, 300)
    status_ts = parse_int((st_obj or {}).get("ts"), 0)
    current_target = str((ops_obj.get("target_chat_url") or ops_obj.get("work_chat_url") or "")).strip()
    current_tab_fp = str((checkpoint_obj.get("fingerprint_v1") or "")).strip()
    current_checkpoint_id = str((checkpoint_obj.get("checkpoint_id") or "")).strip()
    token = read_json(token_path)
    if not isinstance(token, dict):
        token = {}
    token_ts = parse_int(token.get("ts"), 0)
    token_target = str(token.get("target_chat_url") or "").strip()
    token_tab_fp = str(token.get("tab_fingerprint_v1") or "").strip()
    token_checkpoint_id = str(token.get("checkpoint_id") or "").strip()
    fresh = False
    reason = ""
    age_sec = None
    basis_ts = status_ts or now_ts
    if token_ts <= 0:
        reason = "missing"
    else:
        age_sec = max(0, basis_ts - token_ts)
        if age_sec > ttl_sec:
            reason = "expired"
        elif not current_target:
            reason = "current_target_missing"
        elif not token_target:
            reason = "token_target_missing"
        elif token_target != current_target:
            reason = "target_mismatch"
        elif not current_tab_fp:
            reason = "current_tab_fingerprint_missing"
        elif not token_tab_fp:
            reason = "token_tab_fingerprint_missing"
        elif token_tab_fp != current_tab_fp:
            reason = "tab_fingerprint_mismatch"
        else:
            fresh = True
    return {
        "token_path": str(token_path),
        "ttl_sec": ttl_sec,
        "fresh": bool(fresh),
        "reason_not_fresh": ("" if fresh else (reason or "unknown")),
        "last_ok_at": (token_ts if token_ts > 0 else None),
        "age_sec": (age_sec if age_sec is not None else None),
        "current": {
            "status_ts": (status_ts if status_ts > 0 else None),
            "target_chat_url": current_target,
            "tab_fingerprint_v1": current_tab_fp,
            "checkpoint_id": current_checkpoint_id,
        },
        "token": {
            "schema_version": str(token.get("schema_version") or ""),
            "ts": (token_ts if token_ts > 0 else None),
            "target_chat_url": token_target,
            "tab_fingerprint_v1": token_tab_fp,
            "checkpoint_id": token_checkpoint_id,
        },
    }

st = read_json(status_path)
ops = st.get("ops") or {}
checkpoint = st.get("checkpoint") or {}
multi_tabs_obj = st.get("multi_tabs") or {}
blockers = list(st.get("blockers") or [])
warnings = list(st.get("warnings") or [])
next_actions = list(st.get("next_actions") or [])
latest = st.get("latest_run") or {}
latest_outcome = str((latest.get("outcome") or "")).strip()
latest_reason = str((latest.get("reason") or "")).strip()
latest_exit_status_raw = (latest.get("exit_status"))
try:
    latest_exit_status = int(latest_exit_status_raw) if latest_exit_status_raw is not None else 0
except Exception:
    latest_exit_status = 0
last_protocol_event = (ops.get("last_protocol_event") or {})
last_protocol_meta = str((last_protocol_event.get("meta") or "")).strip()
last_protocol_action = str((last_protocol_event.get("action") or "")).strip()
preflight = build_preflight_state(root, preflight_token_path, st, ops, checkpoint)
preflight_fresh = bool(preflight.get("fresh"))
if isinstance(multi_tabs_obj, dict):
    multi_tabs_present = bool(multi_tabs_obj.get("present")) if "present" in multi_tabs_obj else bool("multiple_chat_tabs" in blockers or "multiple_chat_tabs" in warnings or int(ops.get("tab_count") or 0) > 1)
    multi_tabs_severity = str((multi_tabs_obj.get("severity") or "")).strip()
else:
    multi_tabs_present = bool("multiple_chat_tabs" in blockers or "multiple_chat_tabs" in warnings or int(ops.get("tab_count") or 0) > 1)
    multi_tabs_severity = ""
if not multi_tabs_severity:
    if "multiple_chat_tabs" in blockers:
        multi_tabs_severity = "block"
    elif "multiple_chat_tabs" in warnings:
        multi_tabs_severity = "warning"
    else:
        multi_tabs_severity = "none"

def msg_sig(s: str) -> str:
    if not s:
        return ""
    h = hashlib.sha256(s.encode("utf-8", errors="ignore")).hexdigest()[:12]
    return f"{h}:{len(s)}"

def iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")

def dedupe_keep(items):
    out = []
    for x in items or []:
        s = str(x or "").strip()
        if s and s not in out:
            out.append(s)
    return out

def action_mode(action_id: str) -> str:
    if action_id == "ACK":
        return "control"
    if action_id.startswith("STEP_") or action_id in ("RETRY_SAME_STEP", "DELEGATE_SEND_PIPELINE"):
        return "step"
    return "read"

def action_requires_message(action_id: str) -> bool:
    return action_id in ("STEP_SEND", "DELEGATE_SEND_PIPELINE")

def action_requires_user(action_id: str) -> bool:
    return action_id in ("ABORT_SAFE",)

def action_autostep_allowed(action_id: str) -> bool:
    # Bounded auto policy (facade-level): no delegated send, no hidden routing/navigation.
    return action_id in ("ACK", "RUN_STATUS", "RUN_EXPLAIN", "STEP_PREFLIGHT", "STEP_WAIT_FINISHED")

def action_safety(action_id: str) -> str:
    if action_id == "DELEGATE_SEND_PIPELINE":
        return "guarded_send"
    if action_id == "ACK":
        return "safe"
    if action_id == "ABORT_SAFE":
        return "user"
    return "safe"

def action_command_hint(action_id: str) -> str:
    mapping = {
        "ACK": "chatgpt_send --ack",
        "RUN_STATUS": "chatgpt_send --status --json",
        "RUN_EXPLAIN": "chatgpt_send --explain latest --json",
        "ABORT_SAFE": "chatgpt_send step read",
        "STEP_RECOVER": "chatgpt_send step auto --max-steps 1",
        "STEP_WAIT_FINISHED": "chatgpt_send step auto --max-steps 1",
        "STEP_WAIT_STARTED": "chatgpt_send step auto --max-steps 1",
        "STEP_PREFLIGHT": "chatgpt_send step read --json",
        "STEP_COMPOSER_READY": "chatgpt_send step read --json",
        "RETRY_SAME_STEP": "chatgpt_send step read --json",
        "STEP_SEND": "chatgpt_send step send --message '...'",
        "DELEGATE_SEND_PIPELINE": "chatgpt_send step send --message '...'",
    }
    return mapping.get(action_id, "chatgpt_send step read --json")

def action_rationale(action_id: str, block_reason: str, error_class: str) -> str:
    mapping = {
        "ACK": "Подтвердить прочтение уже полученного ответа без новой отправки.",
        "RUN_STATUS": "Подтвердить текущее состояние маршрута/ack/ledger перед следующим шагом.",
        "RUN_EXPLAIN": "Получить расшифровку причины и evidence.",
        "ABORT_SAFE": "Остановиться без изменений и исправить состояние вручную.",
        "STEP_RECOVER": "Выполнить безопасное восстановление recoverable-состояния.",
        "STEP_WAIT_FINISHED": "Продолжить безопасное ожидание без повторной отправки.",
        "STEP_WAIT_STARTED": "Дождаться старта ответа без resend.",
        "STEP_PREFLIGHT": "Пересобрать read-only план и перепроверить guards/UI.",
        "STEP_COMPOSER_READY": "Проверить готовность composer/send перед отправкой.",
        "RETRY_SAME_STEP": "После recovery/wait снова собрать план и продолжить детерминированно.",
        "STEP_SEND": "Делегировать отправку в существующий безопасный send pipeline.",
        "DELEGATE_SEND_PIPELINE": "Делегировать отправку в ядро с полным набором guards/evidence.",
    }
    base = mapping.get(action_id, "Выполнить следующий рекомендуемый шаг.")
    if error_class and action_id in ("RUN_STATUS", "RUN_EXPLAIN", "STEP_RECOVER"):
        return f"{base} (class={error_class}, block={block_reason})."
    return base

def next_why_now(action_id: str, block_reason: str) -> str:
    if action_id == "DELEGATE_SEND_PIPELINE":
        return "Нет активных блоков; отправка разрешена только через безопасное ядро."
    if action_id == "ACK":
        return "Есть непрочитанный ответ; сначала нужно снять ack-блокировку."
    if action_id == "STEP_RECOVER":
        return "Есть recoverable-блок; сначала безопасное восстановление."
    if action_id == "STEP_WAIT_FINISHED":
        return "Сейчас безопаснее дождаться завершения, чем повторять send."
    if action_id == "RUN_STATUS":
        return "Сначала подтвердить текущее состояние перед следующими действиями."
    if action_id == "RUN_EXPLAIN":
        return "Нужна расшифровка причины перед изменяющими действиями."
    if action_id == "ABORT_SAFE":
        return "Требуется ручное вмешательство; автопродолжение небезопасно."
    return "Это первый безопасный шаг по текущему плану."

def normalize_recommended_ids(ids, mode: str, has_message: bool, block_reason: str):
    out = dedupe_keep(ids)
    if block_reason == "NO_BLOCK" and mode in ("send", "auto") and has_message:
        pref = ["DELEGATE_SEND_PIPELINE"]
        for x in out:
            if x != "STEP_SEND" and x not in pref:
                pref.append(x)
        return pref
    return out or ["RUN_STATUS"]

def build_gates(route_ok: bool, cdp_ok: bool, pending_unacked: bool, message_present: bool, strict_single_chat: bool, ledger_state: str, status_partial: bool, checkpoint_stage: str, preflight_fresh: bool, multi_tabs_present: bool, multi_tabs_severity: str):
    gates = [
        f"strict_single_chat_passed={'true' if (route_ok and strict_single_chat) else ('unknown' if not cdp_ok else 'false')}",
        f"cdp_ok={'true' if cdp_ok else 'false'}",
        f"ack_ok={'false' if pending_unacked else 'true'}",
        f"status_partial={'true' if status_partial else 'false'}",
        f"message_present={'true' if message_present else 'false'}",
        f"preflight_fresh={'true' if preflight_fresh else 'false'}",
        f"multi_tabs_present={'true' if multi_tabs_present else 'false'}",
        f"multi_tabs_severity={multi_tabs_severity or 'none'}",
        f"checkpoint_stage={checkpoint_stage or 'null'}",
    ]
    if ledger_state:
        gates.append(f"ledger_state={ledger_state}")
    return gates

def extract_stage_from_meta(meta: str) -> str:
    m = re.search(r"(?:^|\\s)stage=([A-Za-z0-9_:-]+)", str(meta or ""))
    return m.group(1) if m else ""

def read_checkpoint_stage(root_path: pathlib.Path, latest_obj: dict, ops_obj: dict) -> str:
    run_dir = str((latest_obj or {}).get("run_dir") or "").strip()
    if run_dir:
        cp = pathlib.Path(run_dir) / "protocol" / "checkpoint.json"
        try:
            data = json.loads(cp.read_text(encoding="utf-8"))
            for key in ("last_stage", "stage"):
                v = str(data.get(key) or "").strip()
                if v:
                    return v
        except Exception:
            pass
    try:
        meta = str(((ops_obj or {}).get("last_protocol_event") or {}).get("meta") or "")
        v = extract_stage_from_meta(meta)
        if v:
            return v
    except Exception:
        pass
    return ""

def order_recommended(ids, block_reason: str):
    ids = dedupe_keep(ids)
    preferred = {
        "HARD_BLOCK_USER": ["RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"],
        "HARD_BLOCK_ENV": ["RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"],
        "SOFT_BLOCK_RECOVER": ["STEP_RECOVER", "RUN_STATUS", "RETRY_SAME_STEP", "RUN_EXPLAIN"],
        "SOFT_BLOCK_WAIT": ["STEP_WAIT_FINISHED", "RUN_STATUS", "RUN_EXPLAIN"],
        "SOFT_BLOCK_RETRYABLE": ["STEP_PREFLIGHT", "STEP_COMPOSER_READY", "RETRY_SAME_STEP", "RUN_EXPLAIN"],
        "NO_BLOCK": ["STEP_PREFLIGHT", "DELEGATE_SEND_PIPELINE", "RUN_STATUS"],
    }.get(block_reason, [])
    out = []
    for p in preferred:
        if p in ids and p not in out:
            out.append(p)
    for x in ids:
        if x not in out:
            out.append(x)
    return out or ["RUN_STATUS"]

route_ok = bool(int(ops.get("chat_route_ok") or 0))
cdp_ok = bool(int(ops.get("cdp_ok") or 0))
ledger_state = str(((ops.get("ledger_last") or {}).get("state")) or "").strip()
pending_unacked = bool(int(((ops.get("pending_details") or {}).get("pending_unacked")) or 0))

block_reason = "NO_BLOCK"
error_class = "none"
recommended = []
error_code = ""
summary = "Read-only step plan generated."
outcome = "read"
status_value = "ok"

if "reply_unacked" in blockers:
    block_reason = "HARD_BLOCK_USER"
    error_class = "INPUT"
    error_code = "E_ACK_REQUIRED"
    recommended = ["ACK", "RUN_EXPLAIN", "RUN_STATUS"]
    summary = "Blocked: unread reply pending (`--ack` required before next send)."
    outcome = "blocked"
    status_value = "warn"
elif "cdp_down" in blockers:
    block_reason = "HARD_BLOCK_ENV"
    error_class = "ENV"
    error_code = "E_CDP_UNREACHABLE"
    recommended = ["RUN_EXPLAIN", "RUN_STATUS", "ABORT_SAFE"]
    summary = "Blocked: CDP/browser unavailable."
    outcome = "blocked"
    status_value = "error"
elif any(b in blockers for b in ("route_mismatch", "no_target_chat")) or (
    "multiple_chat_tabs" in blockers and (not route_ok or not cdp_ok)
):
    block_reason = "HARD_BLOCK_USER"
    error_class = "ROUTING"
    error_code = "E_ROUTE_MISMATCH"
    recommended = ["RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"]
    summary = "Blocked: routing/target chat state is unsafe."
    outcome = "blocked"
    status_value = "warn"
elif "ledger_pending" in warnings or ledger_state == "pending":
    block_reason = "SOFT_BLOCK_WAIT"
    error_class = "TIMEOUT"
    error_code = str((latest.get("reason") or "")).strip() or "E_WAIT_PENDING"
    recommended = ["STEP_WAIT_FINISHED", "RUN_STATUS", "RUN_EXPLAIN"]
    summary = "Soft block: previous SEND->REPLY cycle is still pending."
    outcome = "blocked"
    status_value = "warn"
elif (
    latest_exit_status == 81
    and (
        "send_retry_veto_intra_run_unconfirmed" in latest_outcome
        or "prompt_not_confirmed_no_resend" in last_protocol_meta
    )
):
    block_reason = "SOFT_BLOCK_RECOVER"
    error_class = "RECOVERY"
    error_code = "E_PROMPT_NOT_CONFIRMED_NO_RESEND"
    recommended = ["RUN_STATUS", "RUN_EXPLAIN", "STEP_PREFLIGHT"]
    summary = "Safety stop after timeout: delivery not confirmed automatically; resend remained blocked."
    outcome = "blocked"
    status_value = "warn"
elif (
    latest_exit_status == 79
    and (
        "confirm_fetch_last_failed" in last_protocol_meta
        or "final_dedupe_fetch_last_failed" in latest_outcome
    )
):
    block_reason = "HARD_BLOCK_ENV"
    error_class = "ENV"
    error_code = "E_CONFIRM_FETCH_LAST_FAILED"
    recommended = ["RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"]
    summary = "Confirm-only/final dedupe could not read chat state (fetch_last failed); resend blocked fail-closed."
    outcome = "blocked"
    status_value = "error"
elif (
    last_protocol_action == "SEND_RETRY_VETO_INTRA_RUN"
    and "prompt_present=1" in last_protocol_meta
):
    block_reason = "SOFT_BLOCK_WAIT"
    error_class = "RECOVERY"
    error_code = "E_SEND_RETRY_VETO_INTRA_RUN"
    recommended = ["STEP_WAIT_FINISHED", "RUN_STATUS", "RUN_EXPLAIN"]
    summary = "Duplicate-safe recovery: prompt already present after timeout; resend vetoed, wait/reuse path selected."
    outcome = "blocked"
    status_value = "warn"
else:
    if mode in ("send", "auto") and message.strip():
        recommended = ["STEP_SEND", "RUN_STATUS"]
        summary = "Ready for delegated send via existing safe pipeline (MVP)."
    elif mode == "send":
        block_reason = "HARD_BLOCK_USER"
        error_class = "INPUT"
        error_code = "E_INPUT_MESSAGE_REQUIRED"
        recommended = ["ABORT_SAFE"]
        summary = "Blocked: step send requires `--message`."
        outcome = "blocked"
        status_value = "warn"
    else:
        recommended = ["STEP_PREFLIGHT", "RUN_STATUS"]

if (
    block_reason == "NO_BLOCK"
    and mode in ("send", "auto")
    and message.strip()
    and not preflight_fresh
):
    block_reason = "SOFT_BLOCK_RETRYABLE"
    error_class = "UI_STATE"
    error_code = "E_PREFLIGHT_STALE"
    recommended = ["STEP_PREFLIGHT", "RUN_STATUS", "RUN_EXPLAIN"]
    summary = "Blocked: delegated send requires a fresh preflight snapshot."
    outcome = "blocked"
    status_value = "warn"

spec_meta = resolve_error_spec_meta_local(error_code) if error_code else None
spec = (spec_meta or {}).get("spec")
resolver_kind = str((spec_meta or {}).get("match_kind") or "")
spec_obj = spec_to_obj(spec)
if spec_obj:
    if spec_obj.get("class"):
        error_class = spec_obj["class"]
    if spec_obj.get("block") and block_reason != "NO_BLOCK":
        block_reason = spec_obj["block"]
    if spec_obj.get("recommended"):
        recommended = list(spec_obj["recommended"])
    if block_reason != "NO_BLOCK" and spec_obj.get("title"):
        summary = f"Blocked: {spec_obj['title']}."

checkpoint_stage = read_checkpoint_stage(root, latest, ops)
status_partial_reasons = []
if not isinstance(st, dict) or not st:
    status_partial_reasons.append("status_missing")
if not str(st.get("schema_version") or "").strip():
    status_partial_reasons.append("status_schema_missing")
if not str(ops.get("target_chat_url") or ops.get("work_chat_url") or "").strip():
    status_partial_reasons.append("target_chat_missing")
if "chat_route_ok" not in ops:
    status_partial_reasons.append("route_probe_missing")
if "cdp_ok" not in ops:
    status_partial_reasons.append("cdp_probe_missing")
if not checkpoint_stage:
    status_partial_reasons.append("checkpoint_stage_missing")
status_partial = any(r for r in status_partial_reasons if r != "checkpoint_stage_missing")

recommended = normalize_recommended_ids(recommended, mode, bool(message.strip()), block_reason)
recommended = order_recommended(recommended, block_reason)
if status_partial and block_reason == "NO_BLOCK":
    recommended = order_recommended(["RUN_STATUS", "RUN_EXPLAIN", "STEP_PREFLIGHT"], "HARD_BLOCK_USER")
next_action_id = recommended[0] if recommended else "RUN_STATUS"
decision_safe_to_autostep = bool(
    not status_partial
    and not bool(message.strip())
    and
    block_reason in ("SOFT_BLOCK_RECOVER", "SOFT_BLOCK_WAIT", "SOFT_BLOCK_RETRYABLE")
    and next_action_id.startswith("STEP_")
    and next_action_id not in ("STEP_SEND", "DELEGATE_SEND_PIPELINE")
)
decision_error = None
if error_code:
    decision_error = {
        "code": error_code,
        "class": error_class,
        "title": (spec_obj.get("title") if spec_obj else ""),
        "why": (spec_obj.get("why") if spec_obj else ""),
        "resolver": (resolver_kind or ("registry" if spec_obj else "none")),
    }
debug_warnings = []
if resolver_kind in ("fallback", "default"):
    debug_warnings.append(f"resolver={resolver_kind}: consider adding exact registry entry for {error_code}")
if status_partial:
    debug_warnings.append("status_partial=true: plan is conservative (no delegated send)")
elif "checkpoint_stage_missing" in status_partial_reasons:
    debug_warnings.append("checkpoint_stage missing: refs.latest_checkpoint.last_stage=null")
recommended_actions = []
for aid in recommended:
    recommended_actions.append({
        "id": aid,
        "mode": action_mode(aid),
        "command_hint": action_command_hint(aid),
        "rationale": action_rationale(aid, block_reason, error_class),
        "requires_user": action_requires_user(aid),
        "requires_message": action_requires_message(aid),
        "autostep_allowed": action_autostep_allowed(aid),
        "safety": action_safety(aid),
        "evidence_refs": list((spec_obj or {}).get("evidence_keys", [])),
    })
gates = build_gates(
    route_ok=route_ok,
    cdp_ok=cdp_ok,
    pending_unacked=pending_unacked,
    message_present=bool(message.strip()),
    strict_single_chat=bool(int(ops.get("strict_single_chat") or 0)),
    ledger_state=ledger_state or "none",
    status_partial=status_partial,
    checkpoint_stage=(checkpoint_stage or ""),
    preflight_fresh=preflight_fresh,
    multi_tabs_present=multi_tabs_present,
    multi_tabs_severity=multi_tabs_severity,
)
operator_notes = []
if pending_unacked:
    operator_notes.append("Сначала прочитайте ответ Specialist и подтвердите `--ack`.")
if "multiple_chat_tabs" in warnings and route_ok and cdp_ok:
    operator_notes.append("Есть лишние ChatGPT `/c/...` вкладки (warning): ядро все равно проверит routing, но лучше закрыть лишние для стабильности.")
if not route_ok and cdp_ok:
    operator_notes.append("Откройте/активируйте правильный work chat и повторите `step read`.")
if block_reason == "NO_BLOCK" and mode in ("send", "auto") and message.strip():
    operator_notes.append("Отправка выполняется только через делегирование в существующий safe pipeline.")
if (
    error_code == "E_PREFLIGHT_STALE"
    and mode in ("send", "auto")
    and message.strip()
):
    operator_notes.insert(0, "Перед делегированием send нужен свежий preflight (`chatgpt_send step read`).")
if status_partial:
    operator_notes.insert(0, "Статус частичный: план переведен в консервативный режим (без delegated send).")
elif not checkpoint_stage:
    operator_notes.append("Checkpoint stage недоступен; refs.latest_checkpoint.last_stage=null.")
if not operator_notes:
    operator_notes.append("Выполняйте `decision.next.action_id` как следующий шаг.")

obj = {
    "schema_version": "step.v1",
    "ts_start": int(time.time()),
    "ts_end": int(time.time()),
    "duration_ms": 0,
    "run_context": {
        "run_id": run_id,
        "project_path": str(root),
        "transport": transport,
        "mode": "live" if transport == "cdp" else "offline",
        "work_chat_url_configured": str(ops.get("target_chat_url") or ""),
        "strict_single_chat": bool(int(ops.get("strict_single_chat") or 0)),
        "busy_policy": str((__import__("os").environ.get("CHATGPT_SEND_BUSY_POLICY") or "auto_stop")),
    },
    "intent": {
        "requested_action": mode,
        "message": message if mode in ("send", "auto") and message else "",
        "message_sig": msg_sig(message),
        "wait_reply": True,
        "auto_ack": True,
        "max_steps": int(max_steps) if str(max_steps).isdigit() else 1,
    },
    "result": {
        "outcome": outcome,
        "status": status_value,
        "summary": summary,
    },
    "state": {
        "route_status": "ok" if route_ok else ("unknown" if not cdp_ok else "mismatch"),
        "ack_pending_before": pending_unacked,
        "ack_pending_after": pending_unacked,
        "stop_visible_before": None,
        "stop_visible_after": None,
        "ledger_state": ledger_state or "none",
        "preflight_fresh": preflight_fresh,
        "multi_tabs": {
            "present": multi_tabs_present,
            "severity": (multi_tabs_severity or "none"),
            "tab_count": int((multi_tabs_obj.get("tab_count") or ops.get("tab_count") or 0) if isinstance(multi_tabs_obj, dict) else (ops.get("tab_count") or 0)),
            "reason": (str(multi_tabs_obj.get("reason") or "") if isinstance(multi_tabs_obj, dict) else ""),
            "hint": (str(multi_tabs_obj.get("hint") or "") if isinstance(multi_tabs_obj, dict) else ""),
        },
    },
    "preflight": preflight,
    "block": {
        "reason": block_reason,
        "error_class": error_class,
        "error_code": error_code,
        "details": {
            "status_blockers": blockers,
            "status_warnings": warnings,
            "status_next_actions": next_actions[:5],
        },
    } if block_reason != "NO_BLOCK" else None,
    "next": {
        "recommended": recommended,
        "safe_to_autostep": decision_safe_to_autostep,
    },
    "actions": [
        {
            "name": "read_status",
            "status": "ok" if st else "error",
            "ts": int(time.time()),
            "detail": {"status_schema": st.get("schema_version", ""), "status": st.get("status", "")},
        }
    ],
    "artifacts": {
        "protocol_jsonl": str(root / "state" / "protocol.jsonl"),
        "checkpoint_json": str(root / "state" / "last_specialist_checkpoint.json"),
        "evidence_dir": str(latest.get("evidence_dir") or ""),
        "run_dir_last": str(latest.get("run_dir") or ""),
    },
    "diagnostics": {
        "error_class": error_class,
        "error_code": error_code,
    },
    "error_spec": spec_obj,
}
obj["schema"] = "step.v1"
obj["generated_at"] = iso_now()
obj["read_only"] = (mode == "read")
obj["scope"] = {
    "workdir": str(root),
    "profile_id": "chrome-profile:unknown",
    "target_chat_key": str(ops.get("target_chat_url") or ops.get("work_chat_url") or ""),
}
obj["summary"] = summary
obj["decision"] = {
    "block_reason": block_reason,
    "safe_to_autostep": decision_safe_to_autostep,
    "error": decision_error,
    "recommended_actions": recommended_actions,
    "next": {
        "action_id": next_action_id,
        "why_now": next_why_now(next_action_id, block_reason),
        "gates": gates,
    },
}
obj["refs"] = {
    "latest_run": {
        "run_id": str(latest.get("run_id") or ""),
        "run_dir": str(latest.get("run_dir") or ""),
    },
    "latest_evidence_dir": str(latest.get("evidence_dir") or ""),
    "latest_checkpoint": {
        "path": str(root / "state" / "last_specialist_checkpoint.json"),
        "last_stage": (checkpoint_stage or None),
    },
    "status_ref": str(root / "state" / "status" / "status.v1.json"),
}
obj["hints"] = {
    "operator_notes": operator_notes,
    "debug": {
        "partial": bool(status_partial),
        "warnings": debug_warnings,
    },
}
if status_partial:
    operator_state = "RECOVERABLE"
elif block_reason == "NO_BLOCK":
    operator_state = "READY"
elif block_reason == "SOFT_BLOCK_WAIT":
    operator_state = "WAITING"
elif block_reason in ("SOFT_BLOCK_RECOVER", "SOFT_BLOCK_RETRYABLE"):
    operator_state = "RECOVERABLE"
elif block_reason == "HARD_BLOCK_ENV" or error_class == "ENV":
    operator_state = "ERROR"
else:
    operator_state = "BLOCKED"

if status_partial:
    operator_why = "partial_status"
elif error_code == "E_PREFLIGHT_STALE":
    operator_why = "stale_preflight"
elif error_code == "E_ACK_REQUIRED":
    operator_why = "ack_required"
elif error_code == "E_CDP_UNREACHABLE":
    operator_why = "cdp_unreachable"
elif error_code == "E_ROUTE_MISMATCH":
    operator_why = "routing_blocked"
elif error_code == "E_SEND_RETRY_VETO_INTRA_RUN":
    operator_why = "confirm_only_after_timeout"
elif error_code == "E_PROMPT_NOT_CONFIRMED_NO_RESEND":
    operator_why = "confirm_failed"
elif error_code:
    operator_why = str(error_code).lower()
else:
    operator_why = "ok_ready_send" if (block_reason == "NO_BLOCK" and mode in ("send", "auto") and message.strip()) else "ok_ready"

operator_confidence = "high"
if status_partial or not cdp_ok:
    operator_confidence = "low"
elif resolver_kind in ("fallback", "default") or (multi_tabs_present and multi_tabs_severity == "warning"):
    operator_confidence = "med"

obj["operator_summary"] = {
    "state": operator_state,
    "why": operator_why,
    "next": next_action_id,
    "note": summary,
    "confidence": operator_confidence,
}
print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
PY
}

chatgpt_send_step_write_preflight_token() {
  local status_json="${1:-}"
  local token_path="$ROOT/state/status/preflight_token.v1.json"
  [[ -n "${status_json:-}" ]] || return 0
  python3 - "$status_json" "$token_path" <<'PY'
import json
import pathlib
import sys
import time

status_path = pathlib.Path(sys.argv[1])
token_path = pathlib.Path(sys.argv[2])

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

st = read_json(status_path)
ops = st.get("ops") or {}
cp = st.get("checkpoint") or {}

def as_int(v, default=0):
    try:
        return int(v)
    except Exception:
        return default

status_ts = as_int(st.get("ts"), 0)
cdp_ok = bool(int((ops.get("cdp_ok") or 0)))
route_ok = bool(int((ops.get("chat_route_ok") or 0)))
target_chat_url = str((ops.get("target_chat_url") or ops.get("work_chat_url") or "")).strip()
tab_fp = str((cp.get("fingerprint_v1") or "")).strip()
checkpoint_id = str((cp.get("checkpoint_id") or "")).strip()

valid = bool(status_ts > 0 and cdp_ok and route_ok and target_chat_url and tab_fp)
token_path.parent.mkdir(parents=True, exist_ok=True)
if not valid:
    try:
        token_path.unlink()
    except FileNotFoundError:
        pass
    raise SystemExit(0)

payload = {
    "schema_version": "preflight_token.v1",
    "ts": status_ts,
    "written_at": int(time.time()),
    "target_chat_url": target_chat_url,
    "tab_fingerprint_v1": tab_fp,
    "checkpoint_id": checkpoint_id,
}
token_path.write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True), encoding="utf-8")
PY
}

chatgpt_send_step_auto_attach_meta() {
  local plan_path="$1" requested_max="$2" steps_executed="$3" actions_csv="$4" stop_reason="$5" forbidden="$6"
  python3 - "$plan_path" "$requested_max" "$steps_executed" "$actions_csv" "$stop_reason" "$forbidden" <<'PY'
import json, sys
path = sys.argv[1]
requested_max = int(sys.argv[2] or 0)
steps_executed = int(sys.argv[3] or 0)
actions = [x for x in (sys.argv[4] or "").split(",") if x]
stop_reason = str(sys.argv[5] or "")
forbidden = str(sys.argv[6] or "")
o = json.load(open(path, encoding="utf-8"))
o["auto"] = {
    "requested_max_steps": requested_max,
    "steps_executed": steps_executed,
    "actions_executed": actions,
    "stop_reason": stop_reason,
    "forbidden_action_detected": forbidden,
}
print(json.dumps(o, ensure_ascii=False, sort_keys=True))
PY
}

chatgpt_send_step_command() {
  local step_mode="${STEP_ACTION:-auto}"
  local step_msg="${STEP_MESSAGE:-}"
  local status_tmp plan_tmp delegate_out delegate_err delegate_rc latest_run
  local step_max="${STEP_MAX_STEPS:-1}"
  if [[ ! "$step_max" =~ ^[0-9]+$ ]]; then
    step_max="1"
  fi
  STEP_MAX_STEPS="$step_max"

  status_tmp="$(mktemp)"
  if ! "$SCRIPT_PATH" --status --json >"$status_tmp" 2>/dev/null; then
    echo "E_STEP_STATUS_FAILED run_id=${RUN_ID}" >&2
    rm -f "$status_tmp" >/dev/null 2>&1 || true
    exit 1
  fi

  plan_tmp="$(mktemp)"
  chatgpt_send_step_emit_plan "$status_tmp" "$step_mode" "$step_msg" >"$plan_tmp"

  if [[ "$step_mode" == "read" ]]; then
    chatgpt_send_step_write_preflight_token "$status_tmp" >/dev/null 2>&1 || true
    if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
      cat "$plan_tmp"
    else
      python3 - "$plan_tmp" <<'PY'
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
print(f"STEP {o['intent']['requested_action']} outcome={o['result']['outcome']} status={o['result']['status']}")
print(f"SUMMARY {o['result']['summary']}")
for a in (o.get("next",{}) or {}).get("recommended",[]) or []:
    print(f"NEXT {a}")
if o.get("block"):
    b=o["block"]
    print(f"BLOCK reason={b.get('reason')} error_class={b.get('error_class')} error_code={b.get('error_code') or 'none'}")
PY
    fi
    rm -f "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
    exit 0
  fi

  # MVP guard: auto is intentionally one transition by default; for now it either
  # blocks/no-ops from read plan or delegates to the existing safe send pipeline.
  local step_next_action_id
  step_block_reason="$(python3 - "$plan_tmp" <<'PY'
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
print((o.get("block") or {}).get("reason") or "NO_BLOCK")
PY
)"
  step_next_action_id="$(python3 - "$plan_tmp" <<'PY'
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
print((((o.get("decision") or {}).get("next") or {}).get("action_id")) or "")
PY
)"

  if [[ "${step_block_reason:-NO_BLOCK}" != "NO_BLOCK" ]]; then
    if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
      if [[ "$step_mode" == "auto" ]]; then
        chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "blocked" ""
      else
        cat "$plan_tmp"
      fi
    else
      python3 - "$plan_tmp" <<'PY'
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
print(f"STEP {o['intent']['requested_action']} outcome=blocked status={o['result']['status']}")
print(f"SUMMARY {o['result']['summary']}")
for a in (o.get('next',{}) or {}).get('recommended',[]) or []:
    print(f"NEXT {a}")
b=o.get('block') or {}
print(f"BLOCK reason={b.get('reason')} error_code={b.get('error_code') or 'none'}")
PY
    fi
    rm -f "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
    exit 73
  fi

  if [[ "$step_mode" == "send" || "$step_mode" == "auto" ]]; then
    if [[ "$step_mode" == "send" && -z "${step_msg//[[:space:]]/}" ]]; then
      echo "E_STEP_MESSAGE_REQUIRED mode=${step_mode} run_id=${RUN_ID}" >&2
      rm -f "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
      exit 2
    fi
    if [[ "$step_mode" == "auto" && "$STEP_MAX_STEPS" == "0" ]]; then
      if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
        chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "max_steps_reached" ""
      else
        echo "STEP auto outcome=no_op status=ok"
        echo "SUMMARY max_steps=0; no mutation performed."
      fi
      rm -f "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
      exit 0
    fi

    delegate_out="$(mktemp)"
    delegate_err="$(mktemp)"
    if [[ "$step_mode" == "auto" ]]; then
      if [[ -z "${step_next_action_id:-}" ]]; then
        if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
          chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "need_plan" ""
        else
          echo "STEP auto outcome=no_op status=warn"
          echo "SUMMARY Planner did not return next action."
        fi
        rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
        exit 74
      fi
      case "$step_next_action_id" in
        ACK|RUN_STATUS|RUN_EXPLAIN|STEP_PREFLIGHT|STEP_WAIT_FINISHED)
          if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
            chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "need_safe_action" ""
          else
            echo "STEP auto outcome=no_op status=ok"
            echo "SUMMARY Bounded auto policy: next safe action is ${step_next_action_id}; run it explicitly (or allow future auto executor)."
            echo "NEXT ${step_next_action_id}"
          fi
          rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
          exit 0
          ;;
        DELEGATE_SEND_PIPELINE|STEP_SEND)
          if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
            chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "need_send" "$step_next_action_id"
          else
            echo "STEP auto outcome=no_op status=warn"
            echo "SUMMARY Bounded auto policy forbids delegated send in step auto."
            echo "NEXT ${step_next_action_id}"
          fi
          rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
          exit 74
          ;;
        *)
          if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
            chatgpt_send_step_auto_attach_meta "$plan_tmp" "$STEP_MAX_STEPS" "0" "" "forbidden_action" "$step_next_action_id"
          else
            echo "STEP auto outcome=no_op status=warn"
            echo "SUMMARY Bounded auto policy forbids action ${step_next_action_id}."
            echo "NEXT RUN_EXPLAIN"
          fi
          rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
          exit 74
          ;;
      esac
    fi

    if [[ -n "${step_next_action_id:-}" && "${step_next_action_id}" != "DELEGATE_SEND_PIPELINE" && "${step_next_action_id}" != "STEP_SEND" ]]; then
      if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
        cat "$plan_tmp"
      else
        echo "STEP ${step_mode} outcome=no_op status=warn"
        echo "SUMMARY Plan does not permit delegated send yet."
        echo "NEXT ${step_next_action_id}"
      fi
      rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
      exit 74
    fi
    set +e
    if [[ -n "${CHATGPT_URL:-}" ]] && is_chat_conversation_url "${CHATGPT_URL:-}"; then
      "$SCRIPT_PATH" --chatgpt-url "${CHATGPT_URL}" --prompt "$step_msg" >"$delegate_out" 2>"$delegate_err"
    else
      "$SCRIPT_PATH" --prompt "$step_msg" >"$delegate_out" 2>"$delegate_err"
    fi
    delegate_rc=$?
    set -e
    latest_run="$(latest_run_dir | head -n 1 || true)"

    if [[ "${OUTPUT_JSON:-0}" == "1" ]]; then
      python3 - "$plan_tmp" "$delegate_rc" "$latest_run" "$delegate_out" "$delegate_err" "$ROOT" "$step_mode" <<'PY'
import json,sys,pathlib,time
plan=json.load(open(sys.argv[1],encoding="utf-8"))
rc=int(sys.argv[2] or 0)
latest_run=sys.argv[3] or ""
out_path=pathlib.Path(sys.argv[4]); err_path=pathlib.Path(sys.argv[5]); root=sys.argv[6]; step_mode=sys.argv[7]
try: out_text=out_path.read_text(encoding='utf-8',errors='ignore')
except Exception: out_text=""
try: err_text=err_path.read_text(encoding='utf-8',errors='ignore')
except Exception: err_text=""
plan["ts_end"]=int(time.time())
plan["result"]["outcome"]="sent" if rc==0 else "failed"
plan["result"]["status"]="ok" if rc==0 else "error"
plan["result"]["summary"]=("Delegated send via existing safe pipeline succeeded (MVP)." if rc==0 else f"Delegated send via existing safe pipeline failed (rc={rc}).")
plan["summary"]=plan["result"]["summary"]
plan["actions"].append({"name":"delegate_send_pipeline","status":"ok" if rc==0 else "error","ts":int(time.time()),"detail":{"rc":rc}})
plan["artifacts"]["run_dir_last"]=latest_run
plan["artifacts"]["delegate_stdout_len"]=len(out_text)
plan["artifacts"]["delegate_stderr_len"]=len(err_text)
plan["artifacts"]["protocol_jsonl"]=str(pathlib.Path(root)/"state"/"protocol.jsonl")
plan["artifacts"]["checkpoint_json"]=str(pathlib.Path(root)/"state"/"last_specialist_checkpoint.json")
if rc==0:
    plan.setdefault("next",{})["recommended"]=["RUN_STATUS"]
    plan.setdefault("decision",{}).setdefault("next",{})["action_id"]="RUN_STATUS"
    plan.setdefault("decision",{}).setdefault("next",{})["why_now"]="Отправка завершена; обновите статус/ack."
    plan.setdefault("decision",{})["block_reason"]="NO_BLOCK"
    plan.setdefault("decision",{})["safe_to_autostep"]=False
    plan.setdefault("decision",{})["error"]=None
else:
    plan.setdefault("next",{})["recommended"]=["RUN_EXPLAIN","RUN_STATUS"]
    plan["diagnostics"]["error_class"]="INTERNAL"
    d=plan.setdefault("decision",{})
    d["block_reason"]="UNKNOWN_BLOCK"
    d["safe_to_autostep"]=False
    d["error"]={"code":f"E_STEP_DELEGATE_RC_{rc}","class":"INTERNAL","title":"Delegated pipeline failed","why":f"Underlying safe pipeline exited rc={rc}.","resolver":"facade"}
    d.setdefault("next",{})["action_id"]="RUN_EXPLAIN"
    d.setdefault("next",{})["why_now"]="Сначала разберите ошибку делегированного pipeline."
print(json.dumps(plan, ensure_ascii=False, sort_keys=True))
PY
    else
      if [[ "$delegate_rc" == "0" ]]; then
        echo "STEP ${step_mode} outcome=sent status=ok"
        echo "SUMMARY Delegated send via existing safe pipeline succeeded (MVP)."
        echo "NEXT RUN_STATUS"
      else
        echo "STEP ${step_mode} outcome=failed status=error"
        echo "SUMMARY Delegated send via existing safe pipeline failed (rc=${delegate_rc})."
        echo "NEXT RUN_EXPLAIN"
        echo "NEXT RUN_STATUS"
      fi
      if [[ -n "${latest_run:-}" ]]; then
        echo "ARTIFACT run_dir=${latest_run}"
      fi
    fi
    rm -f "$delegate_out" "$delegate_err" "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
    exit "$delegate_rc"
  fi

  echo "E_STEP_UNKNOWN_ACTION action=${step_mode} run_id=${RUN_ID}" >&2
  rm -f "$status_tmp" "$plan_tmp" >/dev/null 2>&1 || true
  exit 2
}

chatgpt_send_handle_early_commands() {
# Chat database operations (human-friendly "Specialist sessions")
if [[ $LIST_CHATS -eq 1 ]]; then
  chats_db_list
  exit 0
fi

if [[ $DO_STEP -eq 1 ]]; then
  chatgpt_send_step_command
  exit $?
fi

if [[ $DO_STATUS -eq 1 ]]; then
  chatgpt_send_status_command
  exit $?
fi

if [[ $DO_EXPLAIN -eq 1 ]]; then
  chatgpt_send_explain_command
  exit $?
fi

if [[ -n "${PROBE_CHAT_URL//[[:space:]]/}" ]]; then
  if ! is_chat_conversation_url "${PROBE_CHAT_URL}"; then
    echo "E_ARG_INVALID key=probe_chat_url value=${PROBE_CHAT_URL} run_id=${RUN_ID}" >&2
    exit 2
  fi
  if [[ "${WAIT_ONLY}" == "1" ]]; then
    emit_wait_only_block "probe_chat"
  fi
  CHATGPT_URL="$PROBE_CHAT_URL"
  CHATGPT_URL_EXPLICIT=1
  CHAT_URL_SOURCE="probe_arg"
  timeout_probe="$(resolve_timeout_seconds)"
  probe_out="$(mktemp)"
  echo "PROBE_CHAT_START url=${PROBE_CHAT_URL} transport=${CHATGPT_SEND_TRANSPORT:-cdp} read_only=1 run_id=${RUN_ID}" >&2
  if ! mock_transport_enabled; then
    if ! cdp_is_up; then
      open_browser_impl "${CHATGPT_URL}" || exit 1
    fi
    if ! cdp_is_up; then
      echo "E_PROBE_CHAT_FAILED url=${PROBE_CHAT_URL} code=E_CDP_UNREACHABLE run_id=${RUN_ID}" >&2
      exit 78
    fi
  fi
  set +e
  probe_chat_contract_transport_call "$probe_out" "$PROBE_CHAT_URL" "$timeout_probe"
  probe_rc=$?
  set -e
  probe_log="$(cat "$probe_out" 2>/dev/null || true)"
  rm -f "$probe_out"
  if [[ -n "${probe_log//[[:space:]]/}" ]]; then
    printf '%s\n' "$probe_log" >&2
  fi
  if [[ "$probe_rc" == "0" ]]; then
    echo "PROBE_CHAT_OK url=${PROBE_CHAT_URL} prompt_ready=1"
    exit 0
  fi
  probe_code="E_PROBE_CHAT_FAILED"
  if printf '%s\n' "$probe_log" | grep -Eq 'ui_state=login|E_LOGIN_REQUIRED'; then
    probe_code="E_LOGIN_REQUIRED"
  elif printf '%s\n' "$probe_log" | grep -Eq 'ui_state=captcha|E_CLOUDFLARE|cloudflare|captcha'; then
    probe_code="E_CLOUDFLARE"
  elif printf '%s\n' "$probe_log" | grep -Eq 'missing=composer|composer_missing'; then
    probe_code="E_PROMPT_NOT_FOUND"
  elif printf '%s\n' "$probe_log" | grep -Eq 'E_MOCK_FORCED_FAIL'; then
    probe_code="E_MOCK_FORCED_FAIL"
  fi
  echo "E_PROBE_CHAT_FAILED url=${PROBE_CHAT_URL} code=${probe_code} status=${probe_rc} run_id=${RUN_ID}" >&2
  exit 78
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
