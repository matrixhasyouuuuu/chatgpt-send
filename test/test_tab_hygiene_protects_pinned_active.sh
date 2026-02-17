#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state"

target_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
pinned_url="https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
active_url="https://chatgpt.com/c/cccccccc-cccc-cccc-cccc-cccccccccccc"
other_url="https://chatgpt.com/c/dddddddd-dddd-dddd-dddd-dddddddddddd"
close_log="$tmp/closed_tabs.log"

printf '%s\n' "$pinned_url" >"$root/state/chatgpt_url.txt"
cat >"$root/state/chats.json" <<EOF
{"active":"active","chats":{"active":{"url":"$active_url","title":"Active"}}}
EOF

cat >"$fake_bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
url=""
for a in "\$@"; do
  if [[ "\$a" == http://127.0.0.1:* ]]; then
    url="\$a"
  fi
done
if [[ "\$url" == *"/json/version"* ]]; then
  printf '%s\n' '{"Browser":"fake"}'
  exit 0
fi
if [[ "\$url" == *"/json/list"* ]]; then
  printf '%s\n' '[{"id":"tabA","url":"$target_url","title":"Target","webSocketDebuggerUrl":"ws://fake-a"},{"id":"tabB","url":"$pinned_url","title":"Pinned","webSocketDebuggerUrl":"ws://fake-b"},{"id":"tabC","url":"$active_url","title":"Active","webSocketDebuggerUrl":"ws://fake-c"},{"id":"tabD","url":"$other_url","title":"Other","webSocketDebuggerUrl":"ws://fake-d"}]'
  exit 0
fi
if [[ "\$url" == *"/json/activate/"* ]]; then
  printf '%s\n' '{}'
  exit 0
fi
if [[ "\$url" == *"/json/close/"* ]]; then
  tab_id="\${url##*/}"
  printf '%s\n' "\$tab_id" >>"$close_log"
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
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    prompt = args.prompt or ""
    assistant_text = "tab hygiene test assistant"
    payload = {
        "url": args.chatgpt_url or "",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": prompt,
        "last_user_hash": h(prompt),
        "assistant_text": assistant_text,
        "assistant_tail_hash": h(assistant_text),
        "assistant_tail_len": len(assistant_text),
        "assistant_preview": assistant_text,
        "user_tail_hash": h(prompt),
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h(assistant_text)[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

print("assistant final output", flush=True)
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0
export CHATGPT_SEND_STRICT_SINGLE_CHAT=0
export CHATGPT_SEND_AUTO_TAB_HYGIENE=1
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=0

out="$("$SCRIPT" --chatgpt-url "$target_url" --prompt "tab hygiene protect" 2>&1)"
echo "$out" | rg -q -- 'TAB_HYGIENE start .*mode=safe'
echo "$out" | rg -q -- 'pinned_tab_protect=1'
echo "$out" | rg -q -- 'active_tab_protect=1'

[[ -f "$close_log" ]]
rg -q '^tabD$' "$close_log"
if rg -q 'tabA|tabB|tabC' "$close_log"; then
  echo "unexpected close of target/pinned/active tab" >&2
  cat "$close_log" >&2
  exit 1
fi

echo "OK"
