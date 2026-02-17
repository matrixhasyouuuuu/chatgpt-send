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

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--probe-contract", action="store_true")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

def norm_text(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())

def h(s: str) -> str:
    n = norm_text(s)
    if not n:
        return ""
    return hashlib.sha256(n.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    prompt = args.prompt or ""
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": "baseline",
        "last_user_text_sig": "base12345678:8",
        "last_user_sig": "u-1|||0|8",
        "last_user_hash": h("baseline"),
        "assistant_text": "assistant",
        "assistant_text_sig": "asst12345678:9",
        "last_assistant_sig": "a-1|||1|9",
        "assistant_tail_hash": h("assistant"),
        "assistant_tail_len": 9,
        "assistant_preview": "assistant",
        "user_tail_hash": h("baseline"),
        "ui_state": "ok",
        "ui_contract_sig": "schema=v1|composer=1|send=1|stop=0|assistant_after_anchor=1",
        "fingerprint_v1": h("fp"),
        "norm_version": "v1",
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h("assistant")[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [
            {"role": "user", "text": "baseline", "sig": "u-1|||0|8", "text_len": 8},
            {"role": "assistant", "text": "assistant", "sig": "a-1|||1|9", "text_len": 9},
        ],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    pref = (os.environ.get("CHATGPT_SEND_DISPATCH_PREFERRED") or "").strip().lower()
    if pref == "enter":
        print("SIM_SEND_ENTER_FAIL", flush=True)
        raise SystemExit(3)
    print("SIM_SEND_CLICK_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    print("REPLY_READY: 1", flush=True)
    raise SystemExit(0)

if args.soft_reset_only or args.probe_contract:
    raise SystemExit(0)

pref = (os.environ.get("CHATGPT_SEND_DISPATCH_PREFERRED") or "").strip().lower()
if pref == "enter":
    print("SIM_SEND_ENTER_FAIL", flush=True)
    raise SystemExit(3)
print("dispatch fallback answer", flush=True)
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=0
export CHATGPT_SEND_RUN_ID="run-test-dispatch-fallback-$RANDOM"

out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "dispatch fallback prompt" 2>&1)"
echo "$out" | rg -q -- 'SEND_DISPATCH attempt=1 method=enter'
echo "$out" | rg -q -- 'SEND_DISPATCH attempt=2 method=click'
echo "$out" | rg -q -- 'dispatch fallback answer'
echo "$out" | rg -q -- 'ITER_RESULT outcome=PASS'

echo "OK"
