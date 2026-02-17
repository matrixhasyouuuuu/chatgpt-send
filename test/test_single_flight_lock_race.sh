#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state"

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
import os
import re
import time
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
    payload = {
        "url": args.chatgpt_url or "",
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
            {"role": "user", "text": prompt, "sig": "u-1", "text_len": len(prompt)},
        ],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    n = 0
    try:
        n = int(send_count_file.read_text().strip())
    except Exception:
        n = 0
    if n > 0:
        print("assistant ready from precheck", flush=True)
        raise SystemExit(0)
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    n = 0
    try:
        n = int(send_count_file.read_text().strip())
    except Exception:
        n = 0
    send_count_file.write_text(str(n + 1))
    time.sleep(2.0)
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

print("unsupported", flush=True)
raise SystemExit(3)
PY_EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export CHATGPT_SEND_REPLY_MAX_SEC=3
export CHATGPT_SEND_CHAT_SINGLE_FLIGHT=1
export CHATGPT_SEND_CHAT_LOCK_TIMEOUT_SEC=1
export CHATGPT_SEND_NO_BLIND_RESEND=0
export FAKE_SEND_COUNT="$tmp/send_count.txt"
rm -f "$FAKE_SEND_COUNT"

set +e
"$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "race prompt" >"$tmp/out1.log" 2>&1 &
pid1=$!
sleep 0.2
"$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "race prompt" >"$tmp/out2.log" 2>&1
st2=$?
wait "$pid1"
st1=$?
set -e

if [[ "$st1" -ne 0 ]]; then
  echo "first run failed unexpectedly" >&2
  cat "$tmp/out1.log" >&2
  exit 1
fi
if [[ "$st2" -eq 0 ]]; then
  echo "second run should fail on single-flight lock timeout" >&2
  cat "$tmp/out2.log" >&2
  exit 1
fi

grep -q 'E_CHAT_SINGLE_FLIGHT_TIMEOUT' "$tmp/out2.log"
count="$(cat "$FAKE_SEND_COUNT" 2>/dev/null || echo 0)"
[[ "$count" -eq 1 ]]

echo "OK"
