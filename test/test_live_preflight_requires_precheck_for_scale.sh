#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT_DIR/scripts/live_preflight.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool.txt"
cat >"$pool" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314201
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314202
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314203
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314204
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314205
EOF

ok_out="$(
  RUN_LIVE_CDP_E2E=1 \
  CHATGPT_SEND_TRANSPORT=mock \
  LIVE_CONCURRENCY=5 \
  LIVE_CHAT_POOL_FILE="$pool" \
  LIVE_CHAT_POOL_PRECHECK=1 \
  bash "$PREFLIGHT"
)"
echo "$ok_out" | rg -q -- '^OK_CHAT_POOL=1$'
echo "$ok_out" | rg -q -- '^OK_CHAT_POOL_PRECHECK=1$'
echo "$ok_out" | rg -q -- '^CHAT_POOL_PRECHECK_STATUS=ok$'

bad_url="https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4314202"
set +e
bad_out="$(
  RUN_LIVE_CDP_E2E=1 \
  CHATGPT_SEND_TRANSPORT=mock \
  CHATGPT_SEND_MOCK_PROBE_FAIL_URLS="$bad_url" \
  LIVE_CONCURRENCY=5 \
  LIVE_CHAT_POOL_FILE="$pool" \
  LIVE_CHAT_POOL_PRECHECK=1 \
  bash "$PREFLIGHT" 2>&1
)"
bad_rc=$?
set -e
[[ "$bad_rc" == "16" ]]
echo "$bad_out" | rg -q -- '^OK_CHAT_POOL_PRECHECK=0$'
echo "$bad_out" | rg -q -- '^CHAT_POOL_PRECHECK_STATUS=fail$'
echo "$bad_out" | rg -q -- '^E_CHAT_POOL_PRECHECK_FAILED rc=16$'

echo "OK"
