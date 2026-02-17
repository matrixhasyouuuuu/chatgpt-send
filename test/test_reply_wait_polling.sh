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
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--soft-reset-reason")
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

mode = os.environ.get("FAKE_MODE", "normal")
send_done = Path(os.environ["FAKE_SEND_DONE"])
probe_count = Path(os.environ["FAKE_PROBE_COUNT"])
ready_file = Path(os.environ["FAKE_READY_FILE"])
soft_reset_done = Path(os.environ["FAKE_SOFT_RESET_DONE"])

if args.soft_reset_only:
    soft_reset_done.write_text("1")
    print("SOFT_RESET_OK", flush=True)
    raise SystemExit(0)

if args.precheck_only:
    if not send_done.exists():
        print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
        raise SystemExit(10)
    if mode == "timeout_stop_visible" and soft_reset_done.exists():
        ready_file.write_text("1")
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
    if mode == "progress_stop_visible":
        n = 0
        try:
            n = int(probe_count.read_text().strip())
        except Exception:
            n = 0
        n += 1
        probe_count.write_text(str(n))
        print(f"REPLY_PROGRESS assistant_after_anchor=1 assistant_tail_len={10*n} assistant_tail_hash=hash{n} stop_visible=1", flush=True)
        if n >= 3:
            ready_file.write_text("1")
            print("REPLY_READY: 1", flush=True)
            raise SystemExit(0)
        print("REPLY_READY: 0 reason=stop_visible", flush=True)
        raise SystemExit(10)
    if mode == "timeout_stop_visible":
        print("REPLY_READY: 0 reason=stop_visible", flush=True)
        raise SystemExit(10)
    if mode == "timeout":
        print("REPLY_READY: 0 reason=empty_assistant", flush=True)
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
export FAKE_SOFT_RESET_DONE="$tmp/soft_reset_done.txt"

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

# Ack consumed reply before the timeout scenario to allow next prompt send.
ack_out="$(
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --ack 2>&1
)"
echo "$ack_out" | rg -q -- 'ACK_WRITE'
echo "$ack_out"

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

# Scenario 3: stop_visible with progress should reach ready without soft-reset.
rm -f "$FAKE_SEND_DONE" "$FAKE_PROBE_COUNT" "$FAKE_READY_FILE" "$FAKE_SOFT_RESET_DONE"
export FAKE_MODE="progress_stop_visible"
set +e
out_progress_stop="$(
  CHATGPT_SEND_REPLY_MAX_SEC=2 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "reply wait stop-visible progress" 2>&1
)"
st_progress_stop=$?
set -e
[[ "$st_progress_stop" -eq 0 ]]
echo "$out_progress_stop" | rg -q -- 'REPLY_WAIT done outcome=ready'
if echo "$out_progress_stop" | rg -q -- 'REPLY_WAIT recovery=soft_reset reason=stop_visible_timeout'; then
  echo "unexpected soft-reset on stop-visible with progress" >&2
  exit 1
fi

# Scenario 4: stop_visible timeout -> soft-reset recovery + precheck reuse (without resend).
rm -f "$FAKE_SEND_DONE" "$FAKE_PROBE_COUNT" "$FAKE_READY_FILE" "$FAKE_SOFT_RESET_DONE"
export FAKE_MODE="timeout_stop_visible"
set +e
out_stop_recover="$(
  CHATGPT_SEND_REPLY_MAX_SEC=1 \
  "$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "reply wait stop-visible recover" 2>&1
)"
st_stop_recover=$?
set -e
[[ "$st_stop_recover" -eq 0 ]]
echo "$out_stop_recover" | rg -q -- 'REPLY_WAIT recovery=soft_reset reason=stop_visible_timeout'
echo "$out_stop_recover" | rg -q -- 'REPLY_WAIT done outcome=ready_after_reset'
echo "$out_stop_recover" | rg -q -- 'assistant reply polling answer'
if echo "$out_stop_recover" | rg -q -- 'E_REPLY_WAIT_TIMEOUT'; then
  echo "unexpected timeout after stop-visible recovery" >&2
  exit 1
fi

echo "OK"
