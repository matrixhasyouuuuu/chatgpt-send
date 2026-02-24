#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/live_chat_pool_precheck.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool.txt"
cat >"$pool" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314001
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314002
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314003
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314004
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314005
EOF

out="$(
  CHATGPT_SEND_TRANSPORT=mock \
  bash "$SCRIPT" --chat-pool-file "$pool" --concurrency 5 --transport mock
)"
echo "$out" | rg -q -- '^CHAT_POOL_PRECHECK_OK total=5 ok=5$'
summary_json="$(echo "$out" | sed -n 's/^CHAT_POOL_PRECHECK_SUMMARY_JSON=//p' | tail -n 1)"
test -s "$summary_json"

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if obj.get("total") != 5:
    raise SystemExit(f"expected total=5, got {obj.get('total')}")
if obj.get("ok") != 5:
    raise SystemExit(f"expected ok=5, got {obj.get('ok')}")
if obj.get("fail") != 0:
    raise SystemExit(f"expected fail=0, got {obj.get('fail')}")
PY

echo "OK"
