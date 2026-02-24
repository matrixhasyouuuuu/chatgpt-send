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
EOF
chmod +x "$fake_bin/curl"

cat >"$root/bin/cdp_chatgpt.py" <<'EOF'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
import os

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--send-no-wait", action="store_true")
ap.add_argument("--reply-ready-probe", action="store_true")
ap.add_argument("--soft-reset-only", action="store_true")
ap.add_argument("--soft-reset-reason", default="")
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

state = Path(os.environ["FAKE_STATE_DIR"])
state.mkdir(parents=True, exist_ok=True)
send_count_file = state / "send_count.txt"
fetch_count_file = state / "fetch_count.txt"


def norm_text(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").replace("\u00a0", " ").strip())


def h(s: str) -> str:
    n = norm_text(s)
    return hashlib.sha256(n.encode("utf-8", errors="ignore")).hexdigest() if n else ""


def sig(s: str) -> str:
    n = norm_text(s)
    return f"{h(s)[:12]}:{len(n)}" if n else ""


def bump(p: Path) -> int:
    try:
        n = int(p.read_text().strip())
    except Exception:
        n = 0
    n += 1
    p.write_text(str(n), encoding="utf-8")
    return n


def emit_fetch(prompt: str, include_prompt: bool, assistant_after: bool, assistant_text: str):
    user_text = prompt if include_prompt else ""
    payload = {
        "url": args.chatgpt_url or "",
        "chat_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "stop_visible": False,
        "total_messages": 2 if (user_text or assistant_text) else 0,
        "limit": int(args.fetch_last_n or 6),
        "assistant_after_last_user": bool(assistant_after),
        "last_user_text": user_text,
        "last_user_text_sig": sig(user_text),
        "last_user_sig": "u-1|||0|10" if user_text else "",
        "last_user_hash": h(user_text),
        "assistant_text": assistant_text,
        "assistant_text_sig": sig(assistant_text),
        "last_assistant_sig": "a-1|||1|12" if assistant_text else "",
        "assistant_tail_hash": h(assistant_text[-500:]) if assistant_text else "",
        "assistant_tail_len": len(norm_text(assistant_text)[-500:]) if assistant_text else 0,
        "assistant_preview": assistant_text[:220],
        "user_tail_hash": h(user_text),
        "ui_state": "ok",
        "ui_contract_sig": f"schema=v1|composer=1|send=1|stop=0|assistant_after_anchor={1 if assistant_after else 0}",
        "fingerprint_v1": h("mock-fp"),
        "checkpoint_id": "SPC-2099-01-01T00:00:00Z-" + (h(assistant_text or user_text or 'none')[:8] if (assistant_text or user_text) else "none"),
        "ts": "2099-01-01T00:00:00Z",
        "messages": [],
    }
    if user_text:
        payload["messages"].append({"role": "user", "text": user_text, "sig": payload["last_user_sig"], "text_len": len(user_text)})
    if assistant_text:
        payload["messages"].append({"role": "assistant", "text": assistant_text, "sig": payload["last_assistant_sig"], "text_len": len(assistant_text)})
    print(json.dumps(payload, ensure_ascii=False), flush=True)


if args.fetch_last:
    n = bump(fetch_count_file)
    prompt = args.prompt or ""
    if n <= 2:
        emit_fetch(prompt, include_prompt=False, assistant_after=False, assistant_text="")
    else:
        emit_fetch(prompt, include_prompt=True, assistant_after=True, assistant_text="reply via retry confirm only")
    raise SystemExit(0)

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send")
    raise SystemExit(10)

if args.reply_ready_probe:
    sys.stderr.write("REPLY_READY: 0 reason=prompt_not_echoed\n")
    raise SystemExit(10)

if args.soft_reset_only:
    sys.stderr.write(f"SOFT_RESET start reason={args.soft_reset_reason}\n")
    sys.stderr.write(f"SOFT_RESET done outcome=success reason={args.soft_reset_reason}\n")
    raise SystemExit(0)

send_n = bump(send_count_file)
if send_n == 1:
    sys.stderr.write("RUNTIME_EVAL_TIMEOUT: phase=main\n")
    raise SystemExit(4)

print("UNEXPECTED_SECOND_SEND", flush=True)
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=0
export FAKE_STATE_DIR="$state_dir"

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "status4 no second send" 2>&1)"
st=$?
set -e

[[ "$st" -eq 0 ]]
echo "$out" | rg -q -- 'RUNTIME_EVAL_TIMEOUT'
echo "$out" | rg -q -- 'E_CDP_TIMEOUT_RETRY attempt=1 decision=confirm_only no_resend=1'
echo "$out" | rg -q -- 'SEND_RETRY_VETO_INTRA_RUN reason=intra_run_retry_after_dispatch prompt_present=1'
echo "$out" | rg -q -- 'SEND_VETO_DUPLICATE reason=intra_run_retry_after_dispatch'
echo "$out" | rg -q -- 'REUSE_EXISTING reason=intra_run_retry_after_dispatch'

send_actions="$(printf '%s\n' "$out" | rg -c '^action=send ')"
[[ "$send_actions" -eq 1 ]]

if echo "$out" | rg -q -- 'action=send .*stage=retry_status4_timeout'; then
  echo "unexpected retry_status4_timeout resend" >&2
  exit 1
fi
if echo "$out" | rg -q -- 'UNEXPECTED_SECOND_SEND'; then
  echo "fake cdp second send path was reached" >&2
  exit 1
fi

echo "OK"
