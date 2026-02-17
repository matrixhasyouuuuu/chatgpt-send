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
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--precheck-only", action="store_true")
ap.add_argument("--fetch-last", action="store_true")
ap.add_argument("--fetch-last-n", type=int, default=6)
ap.add_argument("--prompt")
ap.add_argument("--chatgpt-url")
args, _ = ap.parse_known_args()

if args.fetch_last:
    norm = re.sub(r"\s+", " ", (args.prompt or "").strip())
    prompt_hash = hashlib.sha256(norm.encode("utf-8", errors="ignore")).hexdigest() if norm else ""
    assistant_text = "manifest fetch-last"
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

if args.precheck_only:
    sys.stderr.write("E_PRECHECK_NO_NEW_REPLY: need_send\n")
    raise SystemExit(10)

sys.stdout.write("FAKE_OK\n")
raise SystemExit(0)
EOF
chmod +x "$root/bin/cdp_chatgpt.py"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"

export PATH="$fake_bin:$PATH"
run_id="run-manifest-test-$$"
CHATGPT_SEND_ROOT="$root" \
CHATGPT_SEND_RUN_ID="$run_id" \
CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
CHATGPT_SEND_REPLY_POLLING=0 \
"$SCRIPT" --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --prompt "manifest check" >/tmp/test_run_manifest_summary.out 2>/tmp/test_run_manifest_summary.err

manifest="$root/state/runs/$run_id/manifest.json"
summary="$root/state/runs/$run_id/summary.json"
[[ -f "$manifest" ]]
[[ -f "$summary" ]]

python3 - <<PY
import json
from pathlib import Path
manifest = json.loads(Path("$manifest").read_text(encoding="utf-8"))
summary = json.loads(Path("$summary").read_text(encoding="utf-8"))
assert manifest["run_id"] == "$run_id", manifest
assert summary["run_id"] == "$run_id", summary
assert int(summary["exit_status"]) == 0, summary
assert summary["outcome"] in ("ok", "reuse_precheck"), summary
print("OK")
PY
