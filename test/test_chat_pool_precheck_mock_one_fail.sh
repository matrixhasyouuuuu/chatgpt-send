#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/live_chat_pool_precheck.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool.txt"
cat >"$pool" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314101
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314102
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314103
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314104
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314105
EOF
bad_url="https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314103"

set +e
out="$(
  CHATGPT_SEND_TRANSPORT=mock \
  CHATGPT_SEND_MOCK_PROBE_FAIL_URLS="$bad_url" \
  bash "$SCRIPT" --chat-pool-file "$pool" --concurrency 5 --transport mock 2>&1
)"
rc=$?
set -e
[[ "$rc" == "16" ]]
echo "$out" | rg -q -- '^CHAT_POOL_PRECHECK_FAIL total=3 fail=1 code_top=E_MOCK_FORCED_FAIL$'
summary_json="$(echo "$out" | sed -n 's/^CHAT_POOL_PRECHECK_SUMMARY_JSON=//p' | tail -n 1)"
test -s "$summary_json"

python3 - "$summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if obj.get("fail") != 1:
    raise SystemExit(f"expected fail=1, got {obj.get('fail')}")
codes = obj.get("fail_codes") or {}
if codes.get("E_MOCK_FORCED_FAIL") != 1:
    raise SystemExit(f"expected E_MOCK_FORCED_FAIL=1, got {codes}")
PY

echo "OK"
