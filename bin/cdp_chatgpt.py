#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time
import urllib.request

import websocket
from websocket._exceptions import WebSocketBadStatusException, WebSocketTimeoutException


PROGRESS_ENABLED = os.environ.get("CHATGPT_SEND_PROGRESS", "1") != "0"
HEARTBEAT_SEC = float(os.environ.get("CHATGPT_SEND_HEARTBEAT_SEC", "5"))
ACTIVITY_TIMEOUT_SEC = float(os.environ.get("CHATGPT_SEND_ACTIVITY_TIMEOUT_SEC", "45"))


def progress(msg: str) -> None:
    if not PROGRESS_ENABLED:
        return
    sys.stderr.write(f"[cdp_chatgpt] {msg}\n")
    sys.stderr.flush()


def error_marker(code: str, detail: str = "") -> None:
    if detail:
        sys.stderr.write(f"{code}: {detail}\n")
    else:
        sys.stderr.write(f"{code}\n")
    sys.stderr.flush()


def http_json(url: str, timeout: float = 5.0):
    req = urllib.request.Request(url, headers={"User-Agent": "chatgpt-send"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def chat_id_from_url(url: str) -> str | None:
    if not url:
        return None
    m = re.match(r"^https://chatgpt\.com/c/([0-9a-fA-F-]{16,})", url)
    return m.group(1) if m else None


def normalize_url(url: str) -> str:
    return (url or "").split("#", 1)[0].strip()


def find_target_tab(tabs: list[dict], target_url: str) -> dict | None:
    target_url = normalize_url(target_url)
    target_chat_id = chat_id_from_url(target_url)

    # Prefer matching by chat-id (stable even if query params change).
    if target_chat_id:
        for t in tabs:
            u = normalize_url(t.get("url") or "")
            if chat_id_from_url(u) == target_chat_id:
                return t
        sys.stderr.write(f"E_TAB_NOT_FOUND: chat_id_not_found target_chat_id={target_chat_id}\n")
        return None

    # Non-conversation URL: use the last matching ChatGPT tab.
    if target_url.startswith("https://chatgpt.com"):
        is_home = target_url in ("https://chatgpt.com", "https://chatgpt.com/")
        best = None
        best_conv = None
        for t in tabs:
            u = normalize_url(t.get("url") or "")
            if not u.startswith("https://chatgpt.com"):
                continue
            # Prefer "home/new chat" tabs, not /c/ conversation tabs.
            if u.startswith("https://chatgpt.com/c/"):
                best_conv = t
                continue
            best = t
        if best is not None:
            return best
        if not is_home and best_conv is not None:
            return best_conv
        if is_home:
            sys.stderr.write(f"E_TAB_NOT_FOUND: home_tab_missing target_url={target_url}\n")
        else:
            sys.stderr.write(f"E_TAB_NOT_FOUND: no_chatgpt_tabs target_url={target_url}\n")
        return None

    # Exact URL match fallback.
    for t in tabs:
        if normalize_url(t.get("url") or "") == target_url:
            return t
    sys.stderr.write(f"E_TAB_NOT_FOUND: exact_url_not_found target_url={target_url}\n")
    return None


class CDP:
    def __init__(self, ws_url: str, timeout: float = 15.0):
        self.ws = websocket.create_connection(ws_url, timeout=timeout)
        self.ws.settimeout(timeout)
        self.next_id = 1

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass

    def call(self, method: str, params: dict | None = None, timeout: float | None = None) -> dict:
        msg_id = self.next_id
        self.next_id += 1
        payload = {"id": msg_id, "method": method}
        if params:
            payload["params"] = params
        self.ws.send(json.dumps(payload))

        deadline = time.time() + (timeout if timeout is not None else 30.0)
        while True:
            now = time.time()
            if now >= deadline:
                raise TimeoutError(f"CDP timeout waiting for response to {method}")
            remaining = max(0.1, deadline - time.time())
            self.ws.settimeout(remaining)
            try:
                raw = self.ws.recv()
            except (WebSocketTimeoutException, TimeoutError):
                # Transient idle gaps on CDP websocket are expected; keep waiting
                # until our method-level deadline is reached.
                continue
            data = json.loads(raw)
            if data.get("id") == msg_id:
                if "error" in data:
                    raise RuntimeError(f"CDP error for {method}: {data['error']}")
                return data.get("result") or {}
            # Otherwise it's an event; ignore.

    def eval(self, expression: str, timeout: float = 30.0):
        # During navigations/react re-renders, Chrome can throw transient errors like
        # "Execution context was destroyed" / "Promise was collected". Retry a bit.
        last_err = None
        for _ in range(3):
            try:
                res = self.call(
                    "Runtime.evaluate",
                    {
                        "expression": expression,
                        "returnByValue": True,
                        "awaitPromise": True,
                    },
                    timeout=timeout,
                )
                if "exceptionDetails" in res:
                    txt = (res.get("exceptionDetails") or {}).get("text") or "Runtime.evaluate exception"
                    raise RuntimeError(txt)
                r = res.get("result") or {}
                if "value" in r:
                    return r["value"]
                return None
            except RuntimeError as e:
                msg = str(e)
                last_err = e
                if "Execution context was destroyed" in msg or "Promise was collected" in msg:
                    time.sleep(0.15)
                    continue
                raise
            except TimeoutError as e:
                last_err = e
                time.sleep(0.15)
                continue
        if last_err:
            raise last_err
        return None


def js_state_expr() -> str:
    return r"""
(() => {
  const q = (sel) => document.querySelector(sel);
  const qa = (sel) => Array.from(document.querySelectorAll(sel));
  const text = (el) => (el && (el.innerText || el.textContent)) ? (el.innerText || el.textContent) : "";

  const users = qa('[data-message-author-role="user"]');
  const assistants = qa('[data-message-author-role="assistant"]');
  const stop = q('button[data-testid="stop-button"], button[aria-label*="Stop"]');

  const lastUserEl = users.length ? users[users.length - 1] : null;
  const lastU = text(lastUserEl);
  const up = lastUserEl ? lastUserEl.parentElement : null;
  const uidx = (lastUserEl && up) ? Array.from(up.children).indexOf(lastUserEl) : -1;
  const lastUserSig = lastUserEl ? [
    lastUserEl.getAttribute('data-message-id') || '',
    lastUserEl.getAttribute('data-testid') || '',
    lastUserEl.getAttribute('id') || '',
    String(uidx),
    String((lastUserEl.textContent || '').length),
  ].join('|') : "";

  const lastEl = assistants.length ? assistants[assistants.length - 1] : null;
  const lastA = text(lastEl);
  const parent = lastEl ? lastEl.parentElement : null;
  const siblingIndex = (lastEl && parent) ? Array.from(parent.children).indexOf(lastEl) : -1;
  const lastSig = lastEl ? [
    lastEl.getAttribute('data-message-id') || '',
    lastEl.getAttribute('data-testid') || '',
    lastEl.getAttribute('id') || '',
    String(siblingIndex),
    String((lastEl.textContent || '').length),
  ].join('|') : "";
  return {
    url: location.href,
    userCount: users.length,
    lastUser: lastU,
    lastUserSig: lastUserSig,
    assistantCount: assistants.length,
    lastAssistant: lastA,
    lastAssistantSig: lastSig,
    stopVisible: !!stop,
  };
})()
""".strip()


def js_send_ready_expr() -> str:
    return r"""
(() => {
  const q = (sel) => document.querySelector(sel);
  const ed =
    q('#prompt-textarea[contenteditable="true"]') ||
    q('#prompt-textarea') ||
    q('[contenteditable="true"].ProseMirror');
  const form = ed ? (ed.closest('form') || document) : document;
  const btn =
    form.querySelector('button[data-testid="send-button"]') ||
    form.querySelector('button[aria-label="Send prompt"]') ||
    form.querySelector('button[aria-label*="Send"]') ||
    form.querySelector('button[type="submit"]');
  const stop = q('button[data-testid="stop-button"], button[aria-label*="Stop"]');
  return {
    hasEditor: !!ed,
    hasSend: !!btn,
    stopVisible: !!stop,
  };
})()
""".strip()


def js_send_expr(prompt: str) -> str:
    # Use JSON encoding to avoid quoting issues.
    # ChatGPT composer uses a ProseMirror contenteditable div (#prompt-textarea).
    p = json.dumps(prompt)
    return f"""
(() => {{
  const text = {p};
  const q = (sel) => document.querySelector(sel);
  const ed =
    q('#prompt-textarea[contenteditable="true"]') ||
    q('#prompt-textarea') ||
    q('[contenteditable="true"].ProseMirror');
  if (!ed) return {{ok:false, error:'prompt editor not found'}};
  // Clear + insert text in a way ProseMirror/React will notice.
  try {{
    ed.focus();
    const sel = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(ed);
    sel.removeAllRanges();
    sel.addRange(range);
    document.execCommand('insertText', false, text);
  }} catch (e) {{
    // Fallback: replace content directly (may be less reliable).
    ed.textContent = text;
    ed.dispatchEvent(new Event('input', {{bubbles:true}}));
  }}
  const inserted = (ed.innerText || '').trim();
  if (!inserted) return {{ok:false, error:'failed to insert prompt text'}};

  const form = ed.closest('form') || document;
  const btn =
    form.querySelector('button[data-testid="send-button"]') ||
    form.querySelector('button[aria-label="Send prompt"]') ||
    form.querySelector('button[aria-label*="Send"]') ||
    form.querySelector('button[type="submit"]');
  if (btn) {{
    btn.click();
    return {{ok:true, insertedPreview: inserted.slice(0, 60), method:'button'}};
  }}

  // Fallback: when ChatGPT UI hides/renames send button, try Enter send.
  try {{
    ed.focus();
    ed.dispatchEvent(new KeyboardEvent('keydown', {{key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}}));
    ed.dispatchEvent(new KeyboardEvent('keypress', {{key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}}));
    ed.dispatchEvent(new KeyboardEvent('keyup', {{key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}}));
    return {{ok:true, insertedPreview: inserted.slice(0, 60), method:'enter'}};
  }} catch (e) {{
    return {{ok:false, error:'send button not found'}};
  }}
}})()
""".strip()


def js_press_enter_expr() -> str:
    return r"""
(() => {
  const q = (sel) => document.querySelector(sel);
  const ed =
    q('#prompt-textarea[contenteditable="true"]') ||
    q('#prompt-textarea') ||
    q('[contenteditable="true"].ProseMirror');
  if (!ed) return {ok:false, error:'prompt editor not found'};
  try {
    ed.focus();
    ed.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}));
    ed.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}));
    ed.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', which:13, keyCode:13, bubbles:true}));
    return {ok:true, method:'enter-only'};
  } catch (e) {
    return {ok:false, error:'enter-send failed'};
  }
})()
""".strip()


def normalize_assistant_text(s: str) -> str:
    # Normalize whitespace and strip transient typing cursor glyphs.
    txt = re.sub(r"\s+", " ", (s or "").strip())
    txt = re.sub(r"[▍▋▌]+\s*$", "", txt).strip()
    return txt


def normalize_text_for_compare(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip())


def prompt_echo_matches(prompt: str, last_user_text: str) -> bool:
    p = normalize_text_for_compare(prompt)
    u = normalize_text_for_compare(last_user_text)
    if not p or not u:
        return False
    if p == u or p in u or u in p:
        return True
    head = min(len(p), len(u), 64)
    if head >= 24 and p[:head] == u[:head]:
        return True
    tail = min(len(p), len(u), 32)
    if tail >= 24 and p[-tail:] == u[-tail:]:
        return True
    return False


def should_skip_duplicate_send(prompt: str, baseline: dict) -> bool:
    last_user = baseline.get("lastUser") or ""
    return prompt_echo_matches(prompt, last_user)


def wait_for_user_echo(cdp: CDP, baseline: dict, prompt: str, timeout_s: float = 8.0) -> dict | None:
    """Wait until the sent prompt is visible as the newest user message."""
    deadline = time.time() + timeout_s
    state_expr = js_state_expr()
    b_user_count = int(baseline.get("userCount") or 0)
    b_user_sig = (baseline.get("lastUserSig") or "").strip()
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        user_count = int(st.get("userCount") or 0)
        user_sig = (st.get("lastUserSig") or "").strip()
        last_user = st.get("lastUser") or ""
        if user_sig and user_sig != b_user_sig and user_count >= b_user_count:
            if prompt_echo_matches(prompt, last_user):
                return st
        time.sleep(0.25)
    return None


def wait_for_dispatch_signal(cdp: CDP, baseline: dict, max_wait_s: float = 8.0) -> bool:
    """Return True if UI indicates prompt was dispatched (stop/activity/user turn)."""
    deadline = time.time() + max_wait_s
    state_expr = js_state_expr()
    b_user = int(baseline.get("userCount") or 0)
    b_asst = int(baseline.get("assistantCount") or 0)
    b_user_sig = (baseline.get("lastUserSig") or "").strip()
    b_asst_sig = (baseline.get("lastAssistantSig") or "").strip()
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        user_count = int(st.get("userCount") or 0)
        asst_count = int(st.get("assistantCount") or 0)
        user_sig = (st.get("lastUserSig") or "").strip()
        asst_sig = (st.get("lastAssistantSig") or "").strip()
        stop_visible = bool(st.get("stopVisible"))
        if (
            stop_visible
            or user_count > b_user
            or asst_count > b_asst
            or (user_sig and user_sig != b_user_sig)
            or (asst_sig and asst_sig != b_asst_sig)
        ):
            return True
        time.sleep(0.2)
    return False


def wait_for_response(cdp: CDP, baseline: dict, timeout_s: float) -> str:
    t0 = time.time()
    deadline = t0 + timeout_s
    activity_deadline = t0 + min(timeout_s, max(15.0, ACTIVITY_TIMEOUT_SEC))
    state_expr = js_state_expr()

    b_user = int(baseline.get("userCount") or 0)
    b_user_sig = (baseline.get("lastUserSig") or "").strip()
    b_asst = int(baseline.get("assistantCount") or 0)
    b_sig = (baseline.get("lastAssistantSig") or "").strip()

    # Wait until we see response activity. ChatGPT UI may virtualize turns, so
    # assistant/user counters do not always increase.
    saw_activity = False
    saw_stop = False
    next_heartbeat = t0
    while time.time() < activity_deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        user_count = int(st.get("userCount") or 0)
        user_sig = (st.get("lastUserSig") or "").strip()
        asst_count = int(st.get("assistantCount") or 0)
        sig = (st.get("lastAssistantSig") or "").strip()
        stop_visible = bool(st.get("stopVisible"))
        if time.time() >= next_heartbeat:
            progress(
                "phase=wait_activity"
                f" elapsed={time.time()-t0:.1f}s"
                f" user={user_count}/{b_user}"
                f" asst={asst_count}/{b_asst}"
                f" stop={int(stop_visible)}"
                f" user_sig_changed={int(bool(user_sig and user_sig != b_user_sig))}"
                f" asst_sig_changed={int(bool(sig and sig != b_sig))}"
            )
            next_heartbeat = time.time() + HEARTBEAT_SEC
        if stop_visible:
            saw_stop = True
        if (
            user_count > b_user
            or (user_sig and user_sig != b_user_sig)
            or asst_count > b_asst
            or (sig and sig != b_sig)
            or stop_visible
        ):
            saw_activity = True
            progress(
                "phase=wait_activity event=detected"
                f" elapsed={time.time()-t0:.1f}s"
                f" user={user_count} asst={asst_count} stop={int(stop_visible)}"
            )
            break
        time.sleep(0.5)
    else:
        waited = time.time() - t0
        error_marker(
            "E_ACTIVITY_TIMEOUT",
            f"phase=wait_activity waited={waited:.1f}s limit={min(timeout_s, max(15.0, ACTIVITY_TIMEOUT_SEC)):.1f}s",
        )
        raise TimeoutError(
            f"Timed out waiting for assistant response activity "
            f"(phase=wait_activity waited={waited:.1f}s limit={min(timeout_s, max(15.0, ACTIVITY_TIMEOUT_SEC)):.1f}s)"
        )

    # Wait until generation is done: stop button hidden AND last assistant state stabilizes.
    last_marker = None
    last_raw_text = ""
    stable = 0
    changed_vs_baseline = False
    next_heartbeat = time.time()
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        raw_txt = (st.get("lastAssistant") or "").strip()
        txt = normalize_assistant_text(raw_txt)
        user_sig = (st.get("lastUserSig") or "").strip()
        sig = (st.get("lastAssistantSig") or "").strip()
        asst_count = int(st.get("assistantCount") or 0)
        stop_visible = bool(st.get("stopVisible"))
        if time.time() >= next_heartbeat:
            progress(
                "phase=wait_finish"
                f" elapsed={time.time()-t0:.1f}s"
                f" asst={asst_count}/{b_asst}"
                f" stop={int(stop_visible)}"
                f" stable={stable}"
                f" changed={int(changed_vs_baseline)}"
            )
            next_heartbeat = time.time() + HEARTBEAT_SEC
        if stop_visible:
            saw_stop = True
        if asst_count > b_asst or (sig and sig != b_sig) or (user_sig and user_sig != b_user_sig):
            changed_vs_baseline = True

        marker = (sig, txt, asst_count)
        if marker == last_marker:
            stable += 1
        else:
            stable = 0
            last_marker = marker
        if raw_txt:
            last_raw_text = raw_txt

        # If we observed activity and generation is not active, return when
        # the last assistant state stays unchanged for a short period.
        if (
            not stop_visible
            and stable >= 2
            and (changed_vs_baseline or saw_stop or saw_activity)
            and (txt or last_raw_text)
        ):
            progress(f"phase=wait_finish event=completed elapsed={time.time()-t0:.1f}s")
            return (raw_txt or last_raw_text).strip()
        time.sleep(0.5)
    waited_finish = time.time() - t0
    error_marker("E_ACTIVITY_TIMEOUT", f"phase=wait_finish waited={waited_finish:.1f}s")
    raise TimeoutError(f"Timed out waiting for assistant to finish (phase=wait_finish waited={waited_finish:.1f}s)")


def wait_for_composer(cdp: CDP, timeout_s: float = 30.0) -> None:
    deadline = time.time() + timeout_s
    t0 = time.time()
    next_heartbeat = t0
    expr = r"""
(() => {
  const ed =
    document.querySelector('#prompt-textarea[contenteditable="true"]') ||
    document.querySelector('#prompt-textarea') ||
    document.querySelector('[contenteditable="true"].ProseMirror');
  return !!ed;
})()
""".strip()
    while time.time() < deadline:
        try:
            if cdp.eval(expr, timeout=10.0):
                progress(f"phase=wait_composer event=ready elapsed={time.time()-t0:.1f}s")
                return
        except Exception:
            pass
        if time.time() >= next_heartbeat:
            progress(f"phase=wait_composer elapsed={time.time()-t0:.1f}s")
            next_heartbeat = time.time() + HEARTBEAT_SEC
        time.sleep(0.25)
    raise TimeoutError("Timed out waiting for ChatGPT composer to be ready")


def wait_until_send_ready(cdp: CDP, timeout_s: float = 180.0) -> bool:
    """Wait until ChatGPT is idle enough to accept a new message.

    When the assistant is currently generating, the send button is replaced by
    a Stop button. In that state retries with "send button not found" are noisy
    and lead to false "hung" conclusions.
    """
    deadline = time.time() + timeout_s
    t0 = time.time()
    next_heartbeat = t0
    saw_generation_in_progress = False
    expr = js_send_ready_expr()
    while time.time() < deadline:
        st = cdp.eval(expr, timeout=10.0) or {}
        has_editor = bool(st.get("hasEditor"))
        has_send = bool(st.get("hasSend"))
        stop_visible = bool(st.get("stopVisible"))
        if stop_visible:
            if not saw_generation_in_progress:
                error_marker("E_PRECHECK_GENERATION_IN_PROGRESS", "generation_active_before_send")
            saw_generation_in_progress = True
        # hasSend can be false on some UI variants; Enter fallback still works.
        if has_editor and not stop_visible:
            if saw_generation_in_progress:
                error_marker("E_GENERATION_IN_PROGRESS", "waited_until_idle_before_send")
            progress(
                "phase=wait_send_ready event=ready"
                f" elapsed={time.time()-t0:.1f}s"
                f" has_send={int(has_send)}"
            )
            return saw_generation_in_progress
        if time.time() >= next_heartbeat:
            progress(
                "phase=wait_send_ready"
                f" elapsed={time.time()-t0:.1f}s"
                f" has_editor={int(has_editor)}"
                f" has_send={int(has_send)}"
                f" stop={int(stop_visible)}"
            )
            next_heartbeat = time.time() + HEARTBEAT_SEC
        time.sleep(0.5)
    if saw_generation_in_progress:
        error_marker("E_PRECHECK_GENERATION_IN_PROGRESS", "generation_still_active_at_send_ready_timeout")
        error_marker("E_GENERATION_IN_PROGRESS", "still_generating_at_send_ready_timeout")
    raise TimeoutError("Timed out waiting for ChatGPT to become ready for a new prompt")


def ensure_target_route(cdp: CDP, target_url: str) -> bool:
    """Ensure we are on the expected /c/<id> conversation before sending."""
    target_chat_id = chat_id_from_url(target_url)
    if not target_chat_id:
        return True
    state_expr = js_state_expr()
    for attempt in range(1, 3):
        st = cdp.eval(state_expr, timeout=10.0) or {}
        current_url = normalize_url(st.get("url") or "")
        current_chat_id = chat_id_from_url(current_url)
        if current_chat_id == target_chat_id:
            return True
        error_marker(
            "E_ROUTE_MISMATCH",
            f"expected={target_chat_id} got={current_chat_id or 'none'} attempt={attempt}",
        )
        if attempt >= 2:
            break
        try:
            cdp.call("Page.navigate", {"url": target_url}, timeout=10.0)
            progress(f"phase=route_guard event=navigate attempt={attempt}")
        except Exception as e:
            progress(f"phase=route_guard event=navigate_error attempt={attempt} err={e}")
        time.sleep(0.5)
        try:
            wait_for_composer(cdp, timeout_s=20.0)
            wait_until_send_ready(cdp, timeout_s=30.0)
        except Exception:
            pass
    return False


def precheck_reply_before_send(cdp: CDP, target_url: str, prompt: str, timeout_s: float) -> tuple[bool, str]:
    """Check whether a ready answer already exists for this prompt.

    Returns (reused, text). If reused=True, caller should return text and skip send.
    """
    if not ensure_target_route(cdp, target_url):
        error_marker("E_ROUTE_MISMATCH_FATAL", "failed_to_activate_expected_target_chat")
        raise RuntimeError("Route mismatch: failed to activate expected target chat.")

    baseline = cdp.eval(js_state_expr(), timeout=10.0) or {}
    if should_skip_duplicate_send(prompt, baseline):
        stop_visible = bool(baseline.get("stopVisible"))
        existing_answer = (baseline.get("lastAssistant") or "").strip()
        if stop_visible:
            error_marker("E_PRECHECK_GENERATION_IN_PROGRESS", "waiting_existing_generation")
            answer = wait_for_response(cdp, baseline, timeout_s=min(timeout_s, 300.0))
            error_marker("E_PRECHECK_REPLY_ALREADY_AVAILABLE", "completed_existing_generation")
            return True, answer
        if existing_answer:
            error_marker("E_PRECHECK_REPLY_ALREADY_AVAILABLE", "last_user_matches_prompt")
            return True, existing_answer
    error_marker("E_PRECHECK_NO_NEW_REPLY", "need_send")
    return False, ""


def is_generation_in_progress(cdp: CDP) -> bool:
    """Return True when ChatGPT currently shows the Stop button."""
    try:
        st = cdp.eval(js_send_ready_expr(), timeout=10.0) or {}
    except Exception:
        return False
    return bool(st.get("stopVisible"))


def emit_timing(
    *,
    precheck_ms: int | None = None,
    send_ms: int | None = None,
    wait_reply_ms: int | None = None,
    total_ms: int | None = None,
) -> None:
    parts: list[str] = []
    if precheck_ms is not None:
        parts.append(f"precheck_ms={int(precheck_ms)}")
    if send_ms is not None:
        parts.append(f"send_ms={int(send_ms)}")
    if wait_reply_ms is not None:
        parts.append(f"wait_reply_ms={int(wait_reply_ms)}")
    if total_ms is not None:
        parts.append(f"total_ms={int(total_ms)}")
    if not parts:
        return
    sys.stderr.write("TIMING " + " ".join(parts) + "\n")
    sys.stderr.flush()


def mark_timeout_kind(message: str, phase: str = "main") -> None:
    msg = (message or "").lower()
    if "runtime.evaluate" in msg:
        error_marker("RUNTIME_EVAL_TIMEOUT", f"phase={phase}")
    if "composer" in msg:
        error_marker("COMPOSER_TIMEOUT", f"phase={phase}")


def soft_reset_tab(cdp: CDP, target_url: str, reason: str, timeout_s: float = 60.0) -> bool:
    sys.stderr.write(f"SOFT_RESET start reason={reason}\n")
    sys.stderr.flush()
    try:
        try:
            cdp.call("Page.bringToFront", timeout=10.0)
        except Exception:
            pass
        try:
            cdp.call("Page.reload", {"ignoreCache": True}, timeout=15.0)
        except Exception:
            pass

        # Wait page readyState=complete after reload/navigation.
        deadline = time.time() + max(10.0, timeout_s)
        ready_expr = "document.readyState"
        while time.time() < deadline:
            try:
                ready = str(cdp.eval(ready_expr, timeout=10.0) or "").strip().lower()
                if ready == "complete":
                    break
            except TimeoutError as e:
                mark_timeout_kind(str(e), phase="soft_reset_ready_state")
            time.sleep(0.2)

        if not ensure_target_route(cdp, target_url):
            raise RuntimeError("route_mismatch_after_soft_reset")
        wait_for_composer(cdp, timeout_s=30.0)
        wait_until_send_ready(cdp, timeout_s=min(timeout_s, 90.0))
        sys.stderr.write(f"SOFT_RESET done outcome=success reason={reason}\n")
        sys.stderr.flush()
        return True
    except TimeoutError as e:
        mark_timeout_kind(str(e), phase="soft_reset")
        error_marker("E_SOFT_RESET_FAILED", f"reason={reason} err={e}")
        return False
    except Exception as e:
        error_marker("E_SOFT_RESET_FAILED", f"reason={reason} err={e}")
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cdp-port", type=int, default=9222)
    ap.add_argument("--chatgpt-url", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--precheck-only", action="store_true")
    ap.add_argument("--send-no-wait", action="store_true")
    ap.add_argument("--reply-ready-probe", action="store_true")
    ap.add_argument("--soft-reset-only", action="store_true")
    ap.add_argument("--soft-reset-reason", default="manual")
    args = ap.parse_args()
    t_main_start = time.time()
    mode_flags = [args.precheck_only, args.send_no_wait, args.reply_ready_probe, args.soft_reset_only]
    if sum(1 for x in mode_flags if x) > 1:
        sys.stderr.write(
            "Only one mode is allowed: --precheck-only | --send-no-wait | --reply-ready-probe | --soft-reset-only\n"
        )
        return 2

    progress(f"phase=start cdp_port={args.cdp_port} timeout={args.timeout}")
    tabs = http_json(f"http://127.0.0.1:{args.cdp_port}/json/list", timeout=5.0)
    target = find_target_tab(tabs, args.chatgpt_url)
    if not target:
        sys.stderr.write("Could not find target ChatGPT tab in CDP /json/list\n")
        return 2

    ws_url = target.get("webSocketDebuggerUrl")
    progress(f"phase=target_tab_found url={normalize_url(target.get('url') or '')}")
    if not ws_url:
        sys.stderr.write("Target tab is missing webSocketDebuggerUrl\n")
        return 2

    try:
        cdp = CDP(ws_url, timeout=15.0)
        progress("phase=cdp_connect event=ok")
    except WebSocketBadStatusException as e:
        msg = str(e)
        if "remote-allow-origins" in msg or "Rejected an incoming WebSocket connection" in msg:
            sys.stderr.write(
                "CDP WebSocket rejected by Chrome. Re-launch Chrome with "
                "--remote-allow-origins=http://127.0.0.1:<PORT> (or '*').\n"
            )
            return 6
        sys.stderr.write(f"CDP WebSocket handshake failed: {msg}\n")
        return 6
    except Exception as e:
        sys.stderr.write(f"Failed to connect to CDP WebSocket: {e}\n")
        return 6

    try:
        # Enable Runtime/Page for more stable behavior.
        try:
            cdp.call("Runtime.enable", timeout=10.0)
        except Exception:
            pass
        try:
            cdp.call("Page.enable", timeout=10.0)
        except Exception:
            pass

        wait_for_composer(cdp, timeout_s=30.0)
        if args.precheck_only:
            t_precheck_start = time.time()
            reused, text = precheck_reply_before_send(cdp, args.chatgpt_url, args.prompt, timeout_s=float(args.timeout))
            precheck_ms = int((time.time() - t_precheck_start) * 1000)
            if reused:
                emit_timing(precheck_ms=precheck_ms, total_ms=int((time.time() - t_main_start) * 1000))
                sys.stdout.write(text.strip() + "\n")
                return 0
            if is_generation_in_progress(cdp):
                error_marker("E_PRECHECK_GENERATION_IN_PROGRESS", "generation_active_before_send")
                emit_timing(precheck_ms=precheck_ms, total_ms=int((time.time() - t_main_start) * 1000))
                return 11
            emit_timing(precheck_ms=precheck_ms, total_ms=int((time.time() - t_main_start) * 1000))
            return 10
        if args.soft_reset_only:
            ok = soft_reset_tab(cdp, args.chatgpt_url, args.soft_reset_reason, timeout_s=min(float(args.timeout), 120.0))
            return 0 if ok else 4
        if args.reply_ready_probe:
            if not ensure_target_route(cdp, args.chatgpt_url):
                error_marker("E_ROUTE_MISMATCH_FATAL", "failed_to_activate_expected_target_chat")
                return 2
            st = cdp.eval(js_state_expr(), timeout=10.0) or {}
            if not should_skip_duplicate_send(args.prompt, st):
                error_marker("REPLY_READY", "0 reason=prompt_not_echoed")
                return 10
            if bool(st.get("stopVisible")):
                error_marker("REPLY_READY", "0 reason=stop_visible")
                return 10
            existing_answer = (st.get("lastAssistant") or "").strip()
            if existing_answer:
                error_marker("REPLY_READY", "1")
                return 0
            error_marker("REPLY_READY", "0 reason=empty_assistant")
            return 10

        t_send_start = time.time()
        # If ChatGPT is still generating previous answer, wait before sending.
        wait_until_send_ready(cdp, timeout_s=min(float(args.timeout), 300.0))
        if not ensure_target_route(cdp, args.chatgpt_url):
            error_marker("E_ROUTE_MISMATCH_FATAL", "failed_to_activate_expected_target_chat")
            sys.stderr.write("Route mismatch: failed to activate expected target chat.\n")
            return 2

        baseline = cdp.eval(js_state_expr(), timeout=10.0) or {}
        progress(
            "phase=baseline"
            f" user={int(baseline.get('userCount') or 0)}"
            f" asst={int(baseline.get('assistantCount') or 0)}"
        )
        if should_skip_duplicate_send(args.prompt, baseline):
            error_marker("E_DUPLICATE_PROMPT_BLOCKED", "last_user_matches_prompt")
            stop_visible = bool(baseline.get("stopVisible"))
            existing_answer = (baseline.get("lastAssistant") or "").strip()
            if stop_visible:
                progress("phase=dedupe event=wait_existing_generation")
                t_wait_reply_start = time.time()
                answer = wait_for_response(cdp, baseline, timeout_s=float(args.timeout))
                send_ms = int((t_wait_reply_start - t_send_start) * 1000)
                wait_reply_ms = int((time.time() - t_wait_reply_start) * 1000)
                emit_timing(
                    send_ms=send_ms,
                    wait_reply_ms=wait_reply_ms,
                    total_ms=int((time.time() - t_main_start) * 1000),
                )
                progress("phase=done event=answer_ready_dedupe")
                sys.stdout.write(answer.strip() + "\n")
                return 0
            if existing_answer:
                emit_timing(send_ms=int((time.time() - t_send_start) * 1000), total_ms=int((time.time() - t_main_start) * 1000))
                progress("phase=dedupe event=return_last_answer")
                sys.stdout.write(existing_answer + "\n")
                return 0

        send_baseline = dict(baseline)
        send_res = {}
        anchor_state = None
        last_dispatch_state = None
        max_send_attempts = 2
        for attempt in range(1, max_send_attempts + 1):
            send_res = cdp.eval(js_send_expr(args.prompt), timeout=10.0) or {}
            if isinstance(send_res, dict) and send_res.get("ok"):
                method = send_res.get("method", "unknown")
                progress(f"phase=send event=ok method={method} attempt={attempt}")
                dispatched = False
                if wait_for_dispatch_signal(cdp, baseline, max_wait_s=8.0):
                    progress("phase=send event=dispatched")
                    dispatched = True
                else:
                    progress("phase=send event=no_dispatch_after_send retry=enter")
                    enter_res = cdp.eval(js_press_enter_expr(), timeout=10.0) or {}
                    if isinstance(enter_res, dict) and enter_res.get("ok"):
                        if wait_for_dispatch_signal(cdp, baseline, max_wait_s=8.0):
                            progress("phase=send event=dispatched_via_enter")
                            dispatched = True
                if not dispatched:
                    time.sleep(0.15)
                    continue
                try:
                    last_dispatch_state = cdp.eval(js_state_expr(), timeout=10.0) or {}
                except Exception:
                    last_dispatch_state = None

                # Phase-1 post-verify: the new prompt must be echoed as the latest user turn.
                anchor_state = wait_for_user_echo(cdp, baseline, args.prompt, timeout_s=8.0)
                if anchor_state is not None:
                    progress(f"phase=post_verify event=echo_ok attempt={attempt}")
                    baseline = anchor_state
                    break
                error_marker("E_MESSAGE_NOT_ECHOED", f"attempt={attempt}")
                progress(f"phase=post_verify event=echo_miss attempt={attempt}")
                if attempt < max_send_attempts:
                    # Refresh send readiness before one retry.
                    wait_for_composer(cdp, timeout_s=15.0)
                    wait_until_send_ready(cdp, timeout_s=min(float(args.timeout), 60.0))
                    continue
                send_res = {"ok": False, "error": "post-verify user echo failed"}
                break
            err = send_res.get("error") if isinstance(send_res, dict) else "unknown"
            if err in ("send button not found", "prompt editor not found"):
                time.sleep(0.1)
                continue
            break
        if not isinstance(send_res, dict) or not send_res.get("ok"):
            err = send_res.get("error") if isinstance(send_res, dict) else "unknown"
            sys.stderr.write(f"Failed to send prompt in ChatGPT tab: {err}\n")
            return 3
        if anchor_state is None:
            st = last_dispatch_state or {}
            b_user = int(send_baseline.get("userCount") or 0)
            b_user_sig = (send_baseline.get("lastUserSig") or "").strip()
            user_count = int(st.get("userCount") or 0)
            user_sig = (st.get("lastUserSig") or "").strip()
            stop_visible = bool(st.get("stopVisible"))
            if user_count > b_user or (user_sig and user_sig != b_user_sig) or stop_visible:
                error_marker("E_MESSAGE_NOT_ECHOED_SOFT", "using_dispatch_anchor")
                baseline = st if st else baseline
            else:
                error_marker("E_MESSAGE_NOT_ECHOED", "post-verify-anchor-missing")
                sys.stderr.write("Failed to verify sent prompt echo in ChatGPT tab.\n")
                return 3

        if args.send_no_wait:
            emit_timing(send_ms=int((time.time() - t_send_start) * 1000), total_ms=int((time.time() - t_main_start) * 1000))
            progress("phase=done event=send_no_wait_ready")
            return 0

        # Phase-2 post-verify: wait for assistant content after the user anchor.
        t_wait_reply_start = time.time()
        answer = wait_for_response(cdp, baseline, timeout_s=float(args.timeout))
        send_ms = int((t_wait_reply_start - t_send_start) * 1000)
        wait_reply_ms = int((time.time() - t_wait_reply_start) * 1000)
        emit_timing(
            send_ms=send_ms,
            wait_reply_ms=wait_reply_ms,
            total_ms=int((time.time() - t_main_start) * 1000),
        )
        progress("phase=done event=answer_ready")
        sys.stdout.write(answer.strip() + "\n")
        return 0
    except TimeoutError as e:
        mark_timeout_kind(str(e), phase="main")
        sys.stderr.write(str(e) + "\n")
        return 4
    except Exception as e:
        sys.stderr.write(f"CDP automation failed: {e}\n")
        return 5
    finally:
        cdp.close()


if __name__ == "__main__":
    raise SystemExit(main())
