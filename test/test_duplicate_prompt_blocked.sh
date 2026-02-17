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
import os
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

if args.fetch_last:
    import hashlib
    import json
    import re
    norm = re.sub(r"\s+", " ", (args.prompt or "").strip())
    prompt_hash = hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest() if norm else ""
    assistant_text = f"assistant fetch-last for {norm}" if norm else "assistant fetch-last"
    tail = re.sub(r"\s+", " ", assistant_text.strip())[-500:]
    assistant_hash = hashlib.sha256(tail.encode("utf-8", errors="ignore")).hexdigest() if tail else ""
    payload = {
        "url": args.chatgpt_url or "",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": args.prompt or "",
        "last_user_hash": prompt_hash,
        "assistant_text": assistant_text,
        "assistant_tail_hash": assistant_hash,
        "assistant_tail_len": len(tail),
        "assistant_preview": assistant_text[:220],
        "user_tail_hash": prompt_hash,
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + (assistant_hash[:8] if assistant_hash else "none"),
        "ts": "2099-01-01T00:00:00Z",
        "messages": [
            {"role": "user", "text": args.prompt or "", "text_len": len(args.prompt or ""), "tail_hash": prompt_hash, "sig": "u", "preview": (args.prompt or "")[:220]},
            {"role": "assistant", "text": assistant_text, "text_len": len(assistant_text), "tail_hash": assistant_hash, "sig": "a", "preview": assistant_text[:220]},
        ],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

count_file = Path(os.environ["FAKE_SEND_COUNT"])
count = 0
try:
    count = int(count_file.read_text().strip())
except Exception:
    count = 0

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

count += 1
count_file.write_text(str(count))
print(f"assistant reply for {args.prompt}", flush=True)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0
export FAKE_SEND_COUNT="$tmp/send_count.txt"

out1="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "same prompt" 2>&1)"
echo "$out1" | rg -q -- 'assistant reply for same prompt'

set +e
out2="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "same prompt" 2>&1)"
st2=$?
set -e
[[ "$st2" -eq 0 ]]
echo "$out2" | rg -q -- 'REUSE_EXISTING reason=ledger_ready'
if echo "$out2" | rg -q -- 'action=send'; then
  echo "unexpected send on duplicate prompt" >&2
  exit 1
fi

[[ "$(cat "$FAKE_SEND_COUNT")" == "1" ]]

echo "OK"
