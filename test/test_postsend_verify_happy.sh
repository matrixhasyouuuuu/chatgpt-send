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
exit 0
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
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--probe-contract", action="store_true")
ap.add_argument("--soft-reset-reason")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

sent_file = Path(os.environ["FAKE_SENT_FILE"])

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

def sig(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())
    if not norm:
        return ""
    return f"{h(norm)[:12]}:{len(norm)}"

sent = sent_file.exists()

if args.fetch_last:
    prompt = args.prompt or ""
    assistant_text = "postsend happy answer"
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": False if sent else True,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": prompt,
        "last_user_text_sig": sig(prompt),
        "last_user_sig": "u-1|||0|10",
        "last_user_hash": h(prompt),
        "assistant_text": assistant_text if sent else "",
        "assistant_text_sig": sig(assistant_text) if sent else "",
        "last_assistant_sig": "a-1|||1|10" if sent else "",
        "assistant_tail_hash": h(assistant_text) if sent else "",
        "assistant_tail_len": len(assistant_text) if sent else 0,
        "assistant_preview": assistant_text if sent else "",
        "user_tail_hash": h(prompt),
        "ui_state": "ok",
        "ui_contract_sig": "schema=v1|composer=1|send=1|stop=0|assistant_after_anchor=1",
        "fingerprint_v1": h("fp"),
        "norm_version": "v1",
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h("fp")[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [
            {"role": "user", "text": prompt, "sig": "u-1|||0|10", "text_len": len(prompt)},
            {"role": "assistant", "text": assistant_text, "sig": "a-1|||1|10", "text_len": len(assistant_text)},
        ] if sent else [{"role": "user", "text": prompt, "sig": "u-1|||0|10", "text_len": len(prompt)}],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    if sent:
        print("postsend happy answer", flush=True)
        raise SystemExit(0)
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    sent_file.write_text("1")
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    if sent:
        print("REPLY_READY: 1", flush=True)
        raise SystemExit(0)
    print("REPLY_READY: 0 reason=stop_visible", flush=True)
    raise SystemExit(10)

if args.soft_reset_only:
    raise SystemExit(0)

if args.probe_contract:
    raise SystemExit(0)

raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=1
export FAKE_SENT_FILE="$tmp/sent.flag"
rm -f "$FAKE_SENT_FILE"

out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "postsend happy prompt" 2>&1)"
echo "$out" | rg -q -- 'POSTSEND_VERIFY .*result=OK'
echo "$out" | rg -q -- 'SEND_CONFIRMED mode=fetch_last_verify'
echo "$out" | rg -q -- 'postsend happy answer'
if echo "$out" | rg -q -- 'E_SEND_NOT_CONFIRMED'; then
  echo "unexpected send_not_confirmed on happy path" >&2
  exit 1
fi

echo "OK"
