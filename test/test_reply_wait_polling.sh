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
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
ap.add_argument("--cdp-port")
ap.add_argument("--timeout")
args = ap.parse_args()

mode = os.environ.get("FAKE_MODE", "normal")
send_done = Path(os.environ["FAKE_SEND_DONE"])
probe_count = Path(os.environ["FAKE_PROBE_COUNT"])
ready_file = Path(os.environ["FAKE_READY_FILE"])

if args.precheck_only:
    if not send_done.exists():
        print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
        raise SystemExit(10)
    if ready_file.exists():
        print("assistant reply polling answer", flush=True)
        raise SystemExit(0)
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    send_done.write_text("1")
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    if mode == "timeout":
        print("REPLY_READY: 0", flush=True)
        raise SystemExit(10)
    n = 0
    try:
        n = int(probe_count.read_text().strip())
    except Exception:
        n = 0
    n += 1
    probe_count.write_text(str(n))
    if n >= 3:
        ready_file.write_text("1")
        print("REPLY_READY: 1", flush=True)
        raise SystemExit(0)
    print("REPLY_READY: 0", flush=True)
    raise SystemExit(10)

print("unsupported fake invocation", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export FAKE_SEND_DONE="$tmp/send_done.txt"
export FAKE_PROBE_COUNT="$tmp/probe_count.txt"
export FAKE_READY_FILE="$tmp/ready.txt"

# Scenario 1: send-no-wait + reply polling eventually returns answer.
rm -f "$FAKE_SEND_DONE" "$FAKE_PROBE_COUNT" "$FAKE_READY_FILE"
export FAKE_MODE="normal"
set +e
out="$(
  CHATGPT_SEND_REPLY_MAX_SEC=3 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "reply wait normal" 2>&1
)"
st=$?
set -e
[[ "$st" -eq 0 ]]
echo "$out" | rg -q -- 'REPLY_WAIT start'
echo "$out" | rg -q -- 'REPLY_WAIT tick'
echo "$out" | rg -q -- 'REPLY_WAIT done outcome=ready'
echo "$out" | rg -q -- 'action=send'
echo "$out" | rg -q -- 'assistant reply polling answer'

# Scenario 2: reply-ready probe never becomes ready -> bounded timeout.
rm -f "$FAKE_SEND_DONE" "$FAKE_PROBE_COUNT" "$FAKE_READY_FILE"
export FAKE_MODE="timeout"
set +e
out_timeout="$(
  CHATGPT_SEND_REPLY_MAX_SEC=1 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "reply wait timeout" 2>&1
)"
st_timeout=$?
set -e
[[ "$st_timeout" -eq 76 ]]
echo "$out_timeout" | rg -q -- 'REPLY_WAIT done outcome=timeout'
echo "$out_timeout" | rg -q -- 'E_REPLY_WAIT_TIMEOUT'

echo "OK"
