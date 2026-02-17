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
ap.add_argument("--probe-contract", action="store_true")
ap.add_argument("--soft-reset-reason")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

def h(s: str) -> str:
    norm = re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())
    if not norm:
        return ""
    return hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest()

if args.fetch_last:
    prompt = args.prompt or ""
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": prompt,
        "last_user_text_sig": "abcd1234abcd:12",
        "last_user_sig": "u-1|||0|12",
        "last_user_hash": h(prompt),
        "assistant_text": "new answer",
        "assistant_text_sig": "beef5678beef:9",
        "last_assistant_sig": "a-1|||1|9",
        "assistant_tail_hash": h("new answer"),
        "assistant_tail_len": 9,
        "assistant_preview": "new answer",
        "user_tail_hash": h(prompt),
        "ui_contract_sig": "schema=v1|composer=1|send=1|stop=0|assistant_after_anchor=1",
        "fingerprint_v1": "newfingerprint",
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-abcdef12",
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

if args.soft_reset_only:
    print("SOFT_RESET_OK", flush=True)
    raise SystemExit(0)

if args.probe_contract:
    print("UI_CONTRACT_OK", flush=True)
    raise SystemExit(0)

print("unsupported", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

cat >"$root/state/last_specialist_checkpoint.json" <<'EOF'
{
  "chat_url": "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "checkpoint_id": "SPC-prev",
  "fingerprint_v1": "oldfingerprint",
  "last_user_text_sig": "oldsig:1",
  "ts": "2099-01-01T00:00:00Z"
}
EOF

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_PROTO_ENFORCE_FINGERPRINT=1

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "prompt under test" 2>&1)"
st=$?
set -e

[[ "$st" -eq 79 ]]
echo "$out" | rg -q -- 'E_CHAT_FINGERPRINT_MISMATCH'
echo "$out" | rg -q -- 'E_FETCH_LAST_FAILED'
if echo "$out" | rg -q -- 'action=send'; then
  echo "unexpected send on fingerprint mismatch" >&2
  exit 1
fi

echo "OK"
