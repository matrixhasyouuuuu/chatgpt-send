#!/usr/bin/env python3
import argparse
import json
import re
import sys
import time
import urllib.request

import websocket
from websocket._exceptions import WebSocketBadStatusException


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
        return None

    # Non-conversation URL: use the last matching ChatGPT tab.
    if target_url.startswith("https://chatgpt.com"):
        best = None
        for t in tabs:
            u = normalize_url(t.get("url") or "")
            if not u.startswith("https://chatgpt.com"):
                continue
            # Prefer "home/new chat" tabs, not /c/ conversation tabs.
            if u.startswith("https://chatgpt.com/c/"):
                continue
            best = t
        return best

    # Exact URL match fallback.
    for t in tabs:
        if normalize_url(t.get("url") or "") == target_url:
            return t
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
            raw = self.ws.recv()
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


def normalize_assistant_text(s: str) -> str:
    # Normalize whitespace and strip transient typing cursor glyphs.
    txt = re.sub(r"\s+", " ", (s or "").strip())
    txt = re.sub(r"[▍▋▌]+\s*$", "", txt).strip()
    return txt


def wait_for_response(cdp: CDP, baseline: dict, timeout_s: float) -> str:
    deadline = time.time() + timeout_s
    state_expr = js_state_expr()

    b_user = int(baseline.get("userCount") or 0)
    b_asst = int(baseline.get("assistantCount") or 0)
    b_sig = (baseline.get("lastAssistantSig") or "").strip()

    # Wait until we see response activity. ChatGPT UI may virtualize turns, so
    # assistant/user counters do not always increase.
    saw_activity = False
    saw_stop = False
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        user_count = int(st.get("userCount") or 0)
        asst_count = int(st.get("assistantCount") or 0)
        sig = (st.get("lastAssistantSig") or "").strip()
        stop_visible = bool(st.get("stopVisible"))
        if stop_visible:
            saw_stop = True
        if (
            user_count > b_user
            or asst_count > b_asst
            or (sig and sig != b_sig)
            or stop_visible
        ):
            saw_activity = True
            break
        time.sleep(0.5)
    else:
        raise TimeoutError("Timed out waiting for assistant response activity")

    # Wait until generation is done: stop button hidden AND last assistant state stabilizes.
    last_marker = None
    last_raw_text = ""
    stable = 0
    changed_vs_baseline = False
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        raw_txt = (st.get("lastAssistant") or "").strip()
        txt = normalize_assistant_text(raw_txt)
        sig = (st.get("lastAssistantSig") or "").strip()
        asst_count = int(st.get("assistantCount") or 0)
        stop_visible = bool(st.get("stopVisible"))
        if stop_visible:
            saw_stop = True
        if asst_count > b_asst or (sig and sig != b_sig):
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
            return (raw_txt or last_raw_text).strip()
        time.sleep(0.5)
    raise TimeoutError("Timed out waiting for assistant to finish")


def wait_for_composer(cdp: CDP, timeout_s: float = 30.0) -> None:
    deadline = time.time() + timeout_s
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
                return
        except Exception:
            pass
        time.sleep(0.25)
    raise TimeoutError("Timed out waiting for ChatGPT composer to be ready")


def wait_until_send_ready(cdp: CDP, timeout_s: float = 180.0) -> None:
    """Wait until ChatGPT is idle enough to accept a new message.

    When the assistant is currently generating, the send button is replaced by
    a Stop button. In that state retries with "send button not found" are noisy
    and lead to false "hung" conclusions.
    """
    deadline = time.time() + timeout_s
    expr = js_send_ready_expr()
    while time.time() < deadline:
        st = cdp.eval(expr, timeout=10.0) or {}
        has_editor = bool(st.get("hasEditor"))
        stop_visible = bool(st.get("stopVisible"))
        # hasSend can be false on some UI variants; Enter fallback still works.
        if has_editor and not stop_visible:
            return
        time.sleep(0.5)
    raise TimeoutError("Timed out waiting for ChatGPT to become ready for a new prompt")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cdp-port", type=int, default=9222)
    ap.add_argument("--chatgpt-url", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--timeout", type=float, default=900.0)
    args = ap.parse_args()

    tabs = http_json(f"http://127.0.0.1:{args.cdp_port}/json/list", timeout=5.0)
    target = find_target_tab(tabs, args.chatgpt_url)
    if not target:
        sys.stderr.write("Could not find target ChatGPT tab in CDP /json/list\n")
        return 2

    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        sys.stderr.write("Target tab is missing webSocketDebuggerUrl\n")
        return 2

    try:
        cdp = CDP(ws_url, timeout=15.0)
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
        # If ChatGPT is still generating previous answer, wait before sending.
        wait_until_send_ready(cdp, timeout_s=min(float(args.timeout), 300.0))

        baseline = cdp.eval(js_state_expr(), timeout=10.0) or {}
        send_res = {}
        for _ in range(20):
            send_res = cdp.eval(js_send_expr(args.prompt), timeout=10.0) or {}
            if isinstance(send_res, dict) and send_res.get("ok"):
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

        answer = wait_for_response(cdp, baseline, timeout_s=float(args.timeout))
        sys.stdout.write(answer.strip() + "\n")
        return 0
    except TimeoutError as e:
        sys.stderr.write(str(e) + "\n")
        return 4
    except Exception as e:
        sys.stderr.write(f"CDP automation failed: {e}\n")
        return 5
    finally:
        cdp.close()


if __name__ == "__main__":
    raise SystemExit(main())
