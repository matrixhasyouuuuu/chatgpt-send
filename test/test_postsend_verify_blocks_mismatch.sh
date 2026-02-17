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

counter_file = Path(os.environ["FAKE_FETCH_COUNTER"])

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

if args.fetch_last:
    n = 0
    try:
        n = int(counter_file.read_text().strip())
    except Exception:
        n = 0
    n += 1
    counter_file.write_text(str(n))
    prompt = args.prompt or ""
    if n <= 1:
        last_user = "initial baseline"
    else:
        last_user = "wrong echoed prompt"
    assistant_text = "assistant text"
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": False,
        "total_messages": 2,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": True,
        "last_user_text": last_user,
        "last_user_text_sig": sig(last_user),
        "last_user_sig": "u-1|||0|10",
        "last_user_hash": h(last_user),
        "assistant_text": assistant_text,
        "assistant_text_sig": sig(assistant_text),
        "last_assistant_sig": "a-1|||1|12",
        "assistant_tail_hash": h(assistant_text),
        "assistant_tail_len": len(assistant_text),
        "assistant_preview": assistant_text,
        "user_tail_hash": h(last_user),
        "ui_contract_sig": "schema=v1|composer=1|send=1|stop=0|assistant_after_anchor=1",
        "fingerprint_v1": h("fp-" + str(n)),
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + h(assistant_text)[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [
            {"role": "user", "text": last_user, "sig": "u-1|||0|10", "text_len": len(last_user)},
            {"role": "assistant", "text": assistant_text, "sig": "a-1|||1|12", "text_len": len(assistant_text)},
        ],
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

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=1
export CHATGPT_SEND_CAPTURE_EVIDENCE=1
export CHATGPT_SEND_RUN_ID="run-test-postsend-mismatch-$RANDOM"
export FAKE_FETCH_COUNTER="$tmp/fetch_count.txt"
rm -f "$FAKE_FETCH_COUNTER"

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "expected prompt" 2>&1)"
st=$?
set -e

[[ "$st" -eq 81 ]]
echo "$out" | rg -q -- 'E_SEND_NOT_CONFIRMED'
echo "$out" | rg -q -- 'EVIDENCE_CAPTURED'
if echo "$out" | rg -q -- 'REPLY_WAIT start'; then
  echo "reply wait started even though send confirm failed" >&2
  exit 1
fi
ev_dir="$root/state/runs/$CHATGPT_SEND_RUN_ID/evidence"
[[ -d "$ev_dir" ]]
[[ -f "$ev_dir/contract.json" ]]
[[ -f "$ev_dir/tabs.json" ]]
[[ -f "$ev_dir/version.json" ]]
python3 - "$root/state/protocol.jsonl" "$CHATGPT_SEND_RUN_ID" <<'PY'
import json,sys
path, run_id = sys.argv[1], sys.argv[2]
for line in open(path, "r", encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("run_id") == run_id and obj.get("action") == "SEND" and obj.get("status") == "ok":
        raise SystemExit(1)
raise SystemExit(0)
PY

echo "OK"
