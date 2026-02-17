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
import re

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

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    assistant_text = "mismatch chat answer"
    payload = {
        "url": "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
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
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
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

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "route mismatch probe" 2>&1)"
st=$?
set -e

[[ "$st" -eq 79 ]]
echo "$out" | rg -q -- 'CHAT_ROUTE=E_ROUTE_MISMATCH'
echo "$out" | rg -q -- 'E_FETCH_LAST_FAILED'
if echo "$out" | rg -q -- 'action=send'; then
  echo "unexpected send when route mismatch happened" >&2
  exit 1
fi

echo "OK"
