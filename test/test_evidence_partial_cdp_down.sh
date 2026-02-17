#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/fake-bin"
root="$tmp/root"
mkdir -p "$fake_bin" "$root/bin" "$root/docs" "$root/state"

cdp_down_flag="$tmp/cdp_down.flag"

cat >"$fake_bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
url=""
for a in "\$@"; do
  if [[ "\$a" == http://127.0.0.1:* ]]; then
    url="\$a"
  fi
done
if [[ "\$url" == *"/json/version"* ]]; then
  if [[ -f "$cdp_down_flag" ]]; then
    exit 1
  fi
  printf '%s\n' '{"Browser":"fake"}'
  exit 0
fi
if [[ "\$url" == *"/json/list"* ]]; then
  printf '%s\n' '[{"id":"tab1","url":"https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","title":"Fake chat","webSocketDebuggerUrl":"ws://fake"}]'
  exit 0
fi
if [[ "\$url" == *"/json/activate/"* ]] || [[ "\$url" == *"/json/close/"* ]]; then
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
args, _ = ap.parse_known_args()

if args.fetch_last:
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

if args.probe_contract:
    print("UI_CONTRACT: schema_version=v1 has_composer=1 has_send_button=1 has_stop_button=0 can_compute_assistantAfterLastUser=1", flush=True)
    print("UI_CONTRACT_OK: schema_version=v1", flush=True)
    raise SystemExit(0)

if args.precheck_only:
    print("E_PRECHECK_NO_NEW_REPLY: need_send", flush=True)
    raise SystemExit(10)

if args.send_no_wait:
    print("SEND_NO_WAIT_OK", flush=True)
    raise SystemExit(0)

if args.reply_ready_probe:
    flag = os.environ.get("FAKE_CDP_DOWN_FLAG", "")
    if flag:
        try:
            with open(flag, "w", encoding="utf-8") as f:
                f.write("1")
        except Exception:
            pass
    print("REPLY_PROGRESS assistant_after_anchor=0 assistant_tail_len=0 assistant_tail_hash=none stop_visible=1", flush=True)
    print("REPLY_READY: 0 reason=stop_visible", flush=True)
    raise SystemExit(10)

if args.soft_reset_only:
    raise SystemExit(1)

print("unsupported invocation", flush=True)
raise SystemExit(3)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_CDP_PORT="9222"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_POLL_MS=100
export CHATGPT_SEND_REPLY_MAX_SEC=1
export CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS=200
export CHATGPT_SEND_LATE_REPLY_GRACE_SEC=0
export CHATGPT_SEND_CAPTURE_EVIDENCE=1
export CHATGPT_SEND_RUN_ID="run-test-evidence-partial-$RANDOM"
export FAKE_CDP_DOWN_FLAG="$cdp_down_flag"

set +e
out="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "evidence partial cdp down" 2>&1)"
st=$?
set -e
[[ "$st" -eq 76 ]]
echo "$out" | rg -q -- 'EVIDENCE_PARTIAL cdp_ok=0'
echo "$out" | rg -q -- 'EVIDENCE_CAPTURED'

ev_dir="$root/state/runs/$CHATGPT_SEND_RUN_ID/evidence"
[[ -d "$ev_dir" ]]
[[ -f "$ev_dir/ops_snapshot.json" ]]
[[ -f "$ev_dir/ps.txt" ]]
[[ -f "$ev_dir/net.txt" ]]
[[ -f "$ev_dir/env.json" ]]

echo "OK"
