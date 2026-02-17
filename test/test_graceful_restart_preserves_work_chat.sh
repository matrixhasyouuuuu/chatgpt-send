#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/state"

target_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
printf '%s\n' "$target_url" >"$root/state/work_chat_url.txt"
printf '%s\n' "$target_url" >"$root/state/chatgpt_url.txt"

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
ap.add_argument("--probe-contract", action="store_true")
ap.add_argument("--chatgpt-url", default="")
args, _ = ap.parse_known_args()

log_path = os.environ.get("TEST_CDP_LOG")
if log_path:
    with Path(log_path).open("a", encoding="utf-8") as f:
        f.write(" ".join(os.sys.argv[1:]) + "\n")

if args.probe_contract:
    print("UI_CONTRACT: schema_version=v1 has_composer=1 has_send_button=1 has_stop_button=0 can_compute_assistantAfterLastUser=1", flush=True)
    print("UI_CONTRACT_OK: schema_version=v1", flush=True)
    raise SystemExit(0)

if args.precheck_only:
    expected = os.environ.get("TEST_WORK_CHAT_URL", "")
    if args.chatgpt_url == expected:
        print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
        raise SystemExit(10)
    print("E_TAB_NOT_FOUND", flush=True)
    raise SystemExit(2)

print("unsupported", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

cat >"$root/bin/chrome_no_sandbox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.1
EOF
chmod +x "$root/bin/chrome_no_sandbox"

export PATH="$fake_bin:$PATH"
export TEST_CDP_LOG="$tmp/cdp.log"
export TEST_WORK_CHAT_URL="$target_url"

out="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  CHATGPT_SEND_ALLOW_BROWSER_RESTART=1 \
  "$SCRIPT" --graceful-restart-browser 2>&1
)"

echo "$out" | rg -q -- 'BROWSER_RESTART start'
echo "$out" | rg -q -- 'BROWSER_RESTART done ok=1'

actual_work_chat="$(cat "$root/state/work_chat_url.txt")"
[[ "$actual_work_chat" == "$target_url" ]]

rg -q -- '--probe-contract' "$tmp/cdp.log"
rg -q -- '--precheck-only' "$tmp/cdp.log"
rg -q -- "$target_url" "$tmp/cdp.log"

echo "OK"
