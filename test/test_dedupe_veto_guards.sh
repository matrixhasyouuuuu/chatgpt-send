#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for a in "$@"; do
  if [[ "$a" == http://127.0.0.1:* ]]; then
    url="$a"
  fi
done
if [[ "$url" == *"/json/version"* ]]; then
  printf '%s\n' '{"Browser":"fake"}'
  exit 0
fi
if [[ "$url" == *"/json/list"* ]]; then
  printf '%s\n' '[{"id":"tab1","url":"https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","title":"Fake chat","webSocketDebuggerUrl":"ws://fake"}]'
  exit 0
fi
if [[ "$url" == *"/json/activate/"* ]] || [[ "$url" == *"/json/close/"* ]]; then
  printf '%s\n' '{}'
  exit 0
fi
printf '%s\n' '{}'
EOF
chmod +x "$fake_bin/curl"

cat >"$root/bin/cdp_chatgpt.py" <<'EOF'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

case = os.environ.get("FAKE_CASE", "auto_wait_veto")
state_dir = Path(os.environ.get("FAKE_STATE_DIR", "/tmp"))
state_dir.mkdir(parents=True, exist_ok=True)
precheck_state = state_dir / "precheck_count.txt"
fetch_state = state_dir / "fetch_count.txt"


def norm_text(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())


def h(s: str) -> str:
    n = norm_text(s)
    return hashlib.sha256(n.encode("utf-8", errors="ignore")).hexdigest() if n else ""


def sig(s: str) -> str:
    n = norm_text(s)
    return f"{h(s)[:12]}:{len(n)}" if n else ""


def next_count(path: Path) -> int:
    try:
        n = int(path.read_text().strip())
    except Exception:
        n = 0
    n += 1
    path.write_text(str(n), encoding="utf-8")
    return n


def emit_fetch(
    prompt: str,
    *,
    assistant_after: bool,
    stop_visible: bool,
    assistant_text: str = "",
    include_prompt: bool = True,
):
    user_text = prompt if include_prompt else ""
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": bool(stop_visible),
        "total_messages": 2 if (user_text or assistant_text) else 0,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": bool(assistant_after),
        "last_user_text": user_text,
        "last_user_text_sig": sig(user_text),
        "last_user_sig": "u-1|||0|10" if user_text else "",
        "last_user_hash": h(user_text),
        "assistant_text": assistant_text,
        "assistant_text_sig": sig(assistant_text),
        "last_assistant_sig": "a-1|||1|12" if assistant_text else "",
        "assistant_tail_hash": h(assistant_text[-500:]) if assistant_text else "",
        "assistant_tail_len": len(norm_text(assistant_text)[-500:]) if assistant_text else 0,
        "assistant_preview": assistant_text[:220],
        "user_tail_hash": h(user_text),
        "ui_state": "ok",
        "ui_contract_sig": f"schema=v1|composer=1|send=1|stop={1 if stop_visible else 0}|assistant_after_anchor={1 if assistant_after else 0}",
        "fingerprint_v1": h("fp-stable"),
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + (h(assistant_text or user_text or 'none')[:8] if (assistant_text or user_text) else "none"),
        "ts": "2099-01-01T00:00:00Z",
        "messages": [],
    }
    if user_text:
        payload["messages"].append({"role": "user", "text": user_text, "sig": payload["last_user_sig"], "text_len": len(user_text)})
    if assistant_text:
        payload["messages"].append({"role": "assistant", "text": assistant_text, "sig": payload["last_assistant_sig"], "text_len": len(assistant_text)})
    print(json.dumps(payload, ensure_ascii=False), flush=True)


if args.fetch_last:
    fetch_n = next_count(fetch_state)
    prompt = args.prompt or ""
    if case == "auto_wait_veto":
        if fetch_n == 1:
            emit_fetch(prompt, assistant_after=False, stop_visible=False, assistant_text="", include_prompt=False)
        elif fetch_n == 2:
            emit_fetch(prompt, assistant_after=False, stop_visible=False, assistant_text="", include_prompt=True)
        else:
            emit_fetch(prompt, assistant_after=True, stop_visible=False, assistant_text="reply after veto wait", include_prompt=True)
        raise SystemExit(0)
    if case == "final_veto_reuse":
        if fetch_n == 1:
            emit_fetch(prompt, assistant_after=False, stop_visible=False, assistant_text="", include_prompt=False)
        else:
            emit_fetch(prompt, assistant_after=True, stop_visible=False, assistant_text="reply from final dedupe veto", include_prompt=True)
        raise SystemExit(0)
    if case == "final_veto_fetch_fail":
        if fetch_n == 1:
            emit_fetch(prompt, assistant_after=False, stop_visible=False, assistant_text="", include_prompt=False)
            raise SystemExit(0)
        print("FETCH_LAST forced fail", flush=True)
        raise SystemExit(4)

if args.precheck_only:
    n = next_count(precheck_state)
    if case == "auto_wait_veto":
        if n == 1:
            print("E_PRECHECK_GENERATION_IN_PROGRESS: generation_active_before_send", flush=True)
            raise SystemExit(11)
        if n >= 3:
            print("reused reply after auto_wait veto", flush=True)
            raise SystemExit(0)
        print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
        raise SystemExit(10)
    if case in {"final_veto_reuse", "final_veto_fetch_fail"}:
        print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
        raise SystemExit(10)

# If send path is reached in these tests, that's a failure.
print("UNEXPECTED_SEND", flush=True)
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0

run_case() {
  local case_name="$1"
  local prompt="$2"
  local out_var="$3"
  local st_var="$4"
  rm -f "$root/state/"*.txt 2>/dev/null || true
  mkdir -p "$tmp/$case_name"
  export FAKE_CASE="$case_name"
  export FAKE_STATE_DIR="$tmp/$case_name"
  set +e
  local out
  out="$(
    CHATGPT_SEND_AUTO_WAIT_ON_GENERATION=1 \
    CHATGPT_SEND_AUTO_WAIT_MAX_SEC=2 \
    CHATGPT_SEND_AUTO_WAIT_POLL_MS=50 \
    "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "$prompt" 2>&1
  )"
  local st=$?
  set -e
  printf -v "$out_var" '%s' "$out"
  printf -v "$st_var" '%s' "$st"
}

ack_case_reply() {
  local ack_out
  ack_out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --ack 2>&1)"
  echo "$ack_out" | rg -q -- 'ACK_WRITE'
}

# Scenario 1: AUTO_WAIT sees 11->10 but prompt is already present; must veto send
# and reuse later (no SEND_START / action=send).
out1=""
st1=""
run_case "auto_wait_veto" "auto wait duplicate-risk" out1 st1
[[ "$st1" -eq 0 ]]
echo "$out1" | rg -q -- 'AUTO_WAIT start'
echo "$out1" | rg -q -- 'AUTO_WAIT veto outcome=wait reason=prompt_present'
echo "$out1" | rg -q -- 'AUTO_WAIT done outcome=reuse'
echo "$out1" | rg -q -- 'reused reply after auto_wait veto'
if echo "$out1" | rg -q -- 'SEND_START|action=send'; then
  echo "unexpected send in auto_wait_veto scenario" >&2
  exit 1
fi
ack_case_reply

# Scenario 2: prompt appears after precheck (between precheck and send); final
# dedupe choke point must veto and reuse without SEND_START.
out2=""
st2=""
run_case "final_veto_reuse" "final dedupe veto prompt" out2 st2
[[ "$st2" -eq 0 ]]
echo "$out2" | rg -q -- 'SEND_VETO_DUPLICATE'
echo "$out2" | rg -q -- 'REUSE_EXISTING reason=final_dedupe_prompt_present'
if echo "$out2" | rg -q -- 'SEND_START|action=send'; then
  echo "unexpected send in final_veto_reuse scenario" >&2
  exit 1
fi
ack_case_reply

# Scenario 3: final dedupe fetch_last refresh fails -> fail closed (exit 79),
# and still no SEND_START.
out3=""
st3=""
run_case "final_veto_fetch_fail" "final dedupe fetch fail" out3 st3
[[ "$st3" -eq 79 ]]
echo "$out3" | rg -q -- 'E_FETCH_LAST_FAILED required=1 stage=final_dedupe_veto'
if echo "$out3" | rg -q -- 'SEND_START|action=send'; then
  echo "unexpected send in final_veto_fetch_fail scenario" >&2
  exit 1
fi

echo "OK"
