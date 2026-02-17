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
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--probe-contract", action="store_true")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

counter_file = Path(os.environ.get("TEST_SEND_COUNTER_FILE", "/tmp/chatgpt_send_counter.txt"))

if args.fetch_last:
    norm = re.sub(r"\s+", " ", (args.prompt or "").strip())
    prompt_hash = hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest() if norm else ""
    assistant_text = "timeout soak fetch-last"
    assistant_hash = hashlib.sha256(assistant_text.encode("utf-8", errors="ignore")).hexdigest()
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
        "assistant_tail_len": len(assistant_text),
        "assistant_preview": assistant_text,
        "user_tail_hash": prompt_hash,
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + assistant_hash[:8],
        "ts": "2099-01-01T00:00:00Z",
        "messages": [],
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    raise SystemExit(0)

if args.probe_contract:
    raise SystemExit(0)
if args.precheck_only:
    sys.stderr.write("E_PRECHECK_NO_NEW_REPLY: need_send\n")
    raise SystemExit(10)
if args.send_no_wait or (not args.precheck_only and not args.soft_reset_only and not args.probe_contract):
    n = 0
    if counter_file.exists():
        try:
            n = int(counter_file.read_text(encoding="utf-8").strip() or "0")
        except Exception:
            n = 0
    n += 1
    counter_file.write_text(str(n), encoding="utf-8")
    if n == 1:
        sys.stderr.write("COMPOSER_TIMEOUT: phase=main\n")
        raise SystemExit(4)
    sys.stdout.write("SEND_NO_WAIT_OK\n")
    raise SystemExit(0)
if args.soft_reset_only:
    raise SystemExit(0)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export TEST_SEND_COUNTER_FILE="$tmp/send_counter.txt"
out="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  CHATGPT_SEND_REPLY_POLLING=0 \
  CHATGPT_SEND_ALLOW_BROWSER_RESTART=1 \
  CHATGPT_SEND_TIMEOUT_BUDGET_MAX=1 \
  CHATGPT_SEND_TIMEOUT_BUDGET_WINDOW_SEC=300 \
  CHATGPT_SEND_TIMEOUT_BUDGET_ACTION=restart \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "budget restart" 2>&1
)"

echo "$out" | rg -q -- 'E_TIMEOUT_BUDGET_EXCEEDED'
echo "$out" | rg -q -- 'BROWSER_RESTART start reason=timeout_budget'
echo "$out" | rg -q -- 'BROWSER_RESTART done ok=1 reason=timeout_budget'

echo "OK"
