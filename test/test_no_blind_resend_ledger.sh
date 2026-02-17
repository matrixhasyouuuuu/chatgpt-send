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
ap.add_argument("--soft-reset-reason")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

send_done = Path(os.environ["FAKE_SEND_DONE"])
ready_file = Path(os.environ["FAKE_READY_FILE"])
send_count = Path(os.environ["FAKE_SEND_COUNT"])

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    assistant_text = "ledger ready answer"
    payload = {
        "url": args.chatgpt_url or "",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": args.prompt or "",
        "last_user_hash": h(args.prompt or ""),
        "assistant_text": assistant_text,
        "assistant_tail_hash": h(assistant_text),
        "assistant_tail_len": len(assistant_text),
        "assistant_preview": assistant_text,
        "user_tail_hash": h(args.prompt or ""),
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h(assistant_text)[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    if ready_file.exists():
        print("assistant ready from precheck", flush=True)
        raise SystemExit(0)
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    send_done.write_text("1")
    n = 0
    try:
        n = int(send_count.read_text().strip())
    except Exception:
        n = 0
    send_count.write_text(str(n + 1))
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    if send_done.exists():
        ready_file.write_text("1")
        print("REPLY_READY: 1", flush=True)
        raise SystemExit(0)
    print("REPLY_READY: 0 reason=empty_assistant", flush=True)
    raise SystemExit(10)

print("unsupported", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export CHATGPT_SEND_REPLY_MAX_SEC=2
export FAKE_SEND_DONE="$tmp/send_done.txt"
export FAKE_READY_FILE="$tmp/ready.txt"
export FAKE_SEND_COUNT="$tmp/send_count.txt"
rm -f "$FAKE_SEND_DONE" "$FAKE_READY_FILE" "$FAKE_SEND_COUNT"

out1="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "same prompt" 2>&1)"
echo "$out1" | rg -q -- 'action=send'
echo "$out1" | rg -q -- 'REPLY_WAIT done outcome=ready'

out2="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "same prompt" 2>&1)"
echo "$out2" | rg -q -- 'REUSE_EXISTING reason=ledger_ready'
if echo "$out2" | rg -q -- 'action=send'; then
  echo "unexpected send during ledger reuse" >&2
  exit 1
fi

count="$(cat "$FAKE_SEND_COUNT" 2>/dev/null || echo 0)"
[[ "$count" -eq 1 ]]

echo "OK"
