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

fetch_counter = Path(os.environ["FAKE_FETCH_COUNTER"])

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    n = 0
    try:
        n = int(fetch_counter.read_text(encoding="utf-8").strip() or "0")
    except Exception:
        n = 0
    n += 1
    fetch_counter.write_text(str(n), encoding="utf-8")

    if n == 1:
        assistant_text = "late-partial"
    else:
        assistant_text = "late-final-answer"
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

if args.probe_contract:
    raise SystemExit(0)

if args.precheck_only:
    # Keep returning "need_send" so timeout path cannot recover via precheck.
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    print("REPLY_PROGRESS assistant_after_anchor=0 assistant_tail_len=0 assistant_tail_hash=none stop_visible=1", flush=True)
    print("REPLY_READY: 0 reason=stop_visible", flush=True)
    raise SystemExit(10)

if args.soft_reset_only:
    raise SystemExit(0)

print("unsupported invocation", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export CHATGPT_SEND_REPLY_MAX_SEC=1
export CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS=200
export CHATGPT_SEND_LATE_REPLY_GRACE_SEC=3
export CHATGPT_SEND_LATE_REPLY_POLL_MS=200
export CHATGPT_SEND_LATE_REPLY_STABLE_TICKS=2
export FAKE_FETCH_COUNTER="$tmp/fetch_counter.txt"
rm -f "$FAKE_FETCH_COUNTER"

set +e
out="$(
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "late recovery probe" 2>&1
)"
st=$?
set -e

[[ "$st" -eq 0 ]]
echo "$out" | rg -q -- 'W_REPLY_LATE_ARRIVAL'
echo "$out" | rg -q -- 'REPLY_WAIT done outcome=ready_late_recovery'
echo "$out" | rg -q -- 'REPLY_CAPTURE reuse_existing=1 source=late_recovery'
echo "$out" | rg -q -- 'late-final-answer'

echo "OK"
