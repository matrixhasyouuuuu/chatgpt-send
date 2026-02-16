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

  const lastA = assistants.length ? text(assistants[assistants.length - 1]) : "";
  return {
    url: location.href,
    userCount: users.length,
    assistantCount: assistants.length,
    lastAssistant: lastA,
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

  const btn =
    q('button[data-testid="send-button"]') ||
    q('button[aria-label="Send prompt"]') ||
    q('button[aria-label*="Send"]');
  if (!btn) return {{ok:false, error:'send button not found'}};
  btn.click();
  return {{ok:true, insertedPreview: inserted.slice(0, 60)}};
}})()
""".strip()


def wait_for_response(cdp: CDP, baseline: dict, timeout_s: float) -> str:
    deadline = time.time() + timeout_s
    state_expr = js_state_expr()

    b_user = int(baseline.get("userCount") or 0)
    b_asst = int(baseline.get("assistantCount") or 0)

    # Wait until the user message is registered in DOM.
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        if int(st.get("userCount") or 0) >= b_user + 1:
            break
        time.sleep(0.25)
    else:
        raise TimeoutError("Timed out waiting for user message to appear")

    # Wait until an assistant message appears (count increases).
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        if int(st.get("assistantCount") or 0) >= b_asst + 1:
            break
        time.sleep(0.5)
    else:
        raise TimeoutError("Timed out waiting for assistant message to start")

    # Wait until generation is done: stop button hidden AND last assistant text stabilizes.
    last_txt = None
    stable = 0
    while time.time() < deadline:
        st = cdp.eval(state_expr, timeout=10.0) or {}
        txt = (st.get("lastAssistant") or "").strip()
        if txt == last_txt:
            stable += 1
        else:
            stable = 0
            last_txt = txt
        if (not bool(st.get("stopVisible"))) and stable >= 3:
            return txt
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
