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
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

mode = os.environ.get("FAKE_MODE", "send")
state_path = Path(os.environ.get("FAKE_PRECHECK_STATE", "/tmp/fake_precheck_state.txt"))

if args.precheck_only:
    if mode == "timeout":
        print("E_PRECHECK_GENERATION_IN_PROGRESS: generation_active_before_send", flush=True)
        raise SystemExit(11)

    n = 0
    try:
        n = int(state_path.read_text().strip())
    except Exception:
        n = 0

    if n == 0:
        state_path.write_text("1")
        print("E_PRECHECK_GENERATION_IN_PROGRESS: generation_active_before_send", flush=True)
        raise SystemExit(11)

    state_path.write_text("2")
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

print("assistant auto wait answer")
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_AUTO_WAIT_ON_GENERATION=1
export CHATGPT_SEND_REPLY_POLLING=0

# Scenario 1: generation-in-progress -> auto wait -> send.
export FAKE_MODE="send"
export FAKE_PRECHECK_STATE="$tmp/precheck_state_send.txt"
set +e
out="$(
  CHATGPT_SEND_AUTO_WAIT_MAX_SEC=2 \
  CHATGPT_SEND_AUTO_WAIT_POLL_MS=100 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "auto wait send" 2>&1
)"
st=$?
set -e
[[ "$st" -eq 0 ]]
echo "$out" | rg -q -- 'AUTO_WAIT start'
echo "$out" | rg -q -- 'AUTO_WAIT tick'
echo "$out" | rg -q -- 'AUTO_WAIT done outcome=send'
echo "$out" | rg -q -- 'action=send'
echo "$out" | rg -q -- 'assistant auto wait answer'

# Scenario 2: generation stays active -> bounded timeout.
export FAKE_MODE="timeout"
set +e
out_timeout="$(
  CHATGPT_SEND_AUTO_WAIT_MAX_SEC=1 \
  CHATGPT_SEND_AUTO_WAIT_POLL_MS=100 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "auto wait timeout" 2>&1
)"
st_timeout=$?
set -e
[[ "$st_timeout" -eq 73 ]]
echo "$out_timeout" | rg -q -- 'AUTO_WAIT done outcome=timeout'
echo "$out_timeout" | rg -q -- 'E_AUTO_WAIT_TIMEOUT'
if echo "$out_timeout" | rg -q -- 'action=send'; then
  echo "unexpected send after auto-wait timeout" >&2
  exit 1
fi

echo "OK"
