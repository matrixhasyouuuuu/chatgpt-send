#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state"

chat_a="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
chat_b="https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

cat >"$fake_bin/curl" <<'CURL_EOF'
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
CURL_EOF
chmod +x "$fake_bin/curl"

cat >"$root/bin/cdp_chatgpt.py" <<'PY_EOF'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import os
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

send_count_file = Path(os.environ["FAKE_SEND_COUNT"])

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    prompt = args.prompt or ""
    chat_url = args.chatgpt_url or ""
    if chat_url.endswith("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"):
        assistant = "chat-a answer"
        payload = {
            "url": chat_url,
            "stop_visible": False,
            "total_messages": 2,
            "limit": int(args.fetch_last_n or 6),
            "assistant_after_last_user": True,
            "last_user_text": prompt,
            "last_user_hash": h(prompt),
            "assistant_text": assistant,
            "assistant_tail_hash": h(assistant),
            "assistant_tail_len": len(assistant),
            "assistant_preview": assistant,
            "user_tail_hash": h(prompt),
            "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h(assistant)[:8],
            "ts": "2099-01-01T00:00:00Z",
            "messages": [
                {"role": "user", "text": prompt, "sig": "u-a", "text_len": len(prompt)},
                {"role": "assistant", "text": assistant, "sig": "a-a", "text_len": len(assistant)},
            ],
        }
    else:
        payload = {
            "url": chat_url,
            "stop_visible": False,
            "total_messages": 1,
            "limit": int(args.fetch_last_n or 6),
            "assistant_after_last_user": False,
            "last_user_text": "",
            "last_user_hash": "",
            "assistant_text": "",
            "assistant_tail_hash": "",
            "assistant_tail_len": 0,
            "assistant_preview": "",
            "user_tail_hash": h(prompt),
            "checkpoint_id": "",
            "ts": "2099-01-01T00:00:00Z",
            "messages": [
                {"role": "user", "text": prompt, "sig": "u-b", "text_len": len(prompt)},
            ],
        }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    n = 0
    try:
        n = int(send_count_file.read_text().strip())
    except Exception:
        n = 0
    send_count_file.write_text(str(n + 1))
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    print("REPLY_READY: 1", flush=True)
    raise SystemExit(0)

if args.soft_reset_only:
    print("SOFT_RESET_OK", flush=True)
    raise SystemExit(0)

if args.probe_contract:
    print("UI_CONTRACT_OK", flush=True)
    raise SystemExit(0)

# Regular send mode (--send-no-wait is not used when reply polling is disabled).
n = 0
try:
    n = int(send_count_file.read_text().strip())
except Exception:
    n = 0
send_count_file.write_text(str(n + 1))
print("assistant direct mode", flush=True)
raise SystemExit(0)

print("unsupported", flush=True)
raise SystemExit(3)
PY_EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0
export CHATGPT_SEND_NO_BLIND_RESEND=1
export CHATGPT_SEND_STRICT_SINGLE_CHAT=0
export FAKE_SEND_COUNT="$tmp/send_count.txt"
rm -f "$FAKE_SEND_COUNT"

"$SCRIPT" --chatgpt-url "$chat_a" --prompt "same scoped prompt" >/dev/null 2>&1

out2="$($SCRIPT --chatgpt-url "$chat_b" --prompt "same scoped prompt" 2>&1)"
if echo "$out2" | rg -q -- 'REUSE_EXISTING reason=ledger_ready'; then
  echo "unexpected ledger reuse across different chat_url" >&2
  exit 1
fi
echo "$out2" | rg -q -- 'action=send'

count="$(cat "$FAKE_SEND_COUNT" 2>/dev/null || echo 0)"
[[ "$count" -eq 2 ]]

echo "OK"
