#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
state_dir="$tmp/state"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state" "$state_dir"

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
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--soft-reset-reason", default="")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

state = Path(os.environ["FAKE_STATE_DIR"])
attempt = state / "attempt.txt"
reply_ready = state / "reply_ready.txt"

if args.precheck_only:
    if reply_ready.exists():
        print("assistant after soft reset")
        raise SystemExit(0)
    print("E_PRECHECK_NO_NEW_REPLY: need_send")
    raise SystemExit(10)

if args.reply_ready_probe:
    if reply_ready.exists():
        sys.stderr.write("REPLY_READY: 1\n")
        raise SystemExit(0)
    sys.stderr.write("REPLY_READY: 0\n")
    raise SystemExit(10)

if args.soft_reset_only:
    sys.stderr.write(f"SOFT_RESET start reason={args.soft_reset_reason}\n")
    sys.stderr.write(f"SOFT_RESET done outcome=success reason={args.soft_reset_reason}\n")
    raise SystemExit(0)

if not attempt.exists():
    attempt.write_text("1")
    sys.stderr.write("RUNTIME_EVAL_TIMEOUT: phase=send\n")
    raise SystemExit(4)

reply_ready.write_text("1")
print("send dispatched")
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export CHATGPT_SEND_REPLY_MAX_SEC=3
export FAKE_STATE_DIR="$state_dir"

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "runtime eval timeout test" 2>&1)"
st=$?
set -e
[[ "$st" -eq 0 ]]
echo "$out" | rg -q -- 'RUNTIME_EVAL_TIMEOUT'
echo "$out" | rg -q -- 'RETRY_CLASS class=soft_reset'
echo "$out" | rg -q -- 'SOFT_RESET done outcome=success'
echo "$out" | rg -q -- 'assistant after soft reset'
if echo "$out" | rg -q -- 'E_SOFT_RESET_FAILED'; then
  echo "unexpected E_SOFT_RESET_FAILED" >&2
  exit 1
fi

echo "OK"
