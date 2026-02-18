#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGR="$ROOT_DIR/scripts/chat_pool_manage.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bad_pool="$tmp/bad_pool.txt"
cat >"$bad_pool" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312001
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312001
https://chatgpt.com/not-a-chat
EOF

set +e
bad_out="$("$MGR" validate --chat-pool-file "$bad_pool" --min 2 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" == "2" ]]
echo "$bad_out" | rg -q -- '^CHAT_POOL_OK=0$'
echo "$bad_out" | rg -q -- '^CHAT_POOL_INVALID_COUNT=1$'
echo "$bad_out" | rg -q -- '^CHAT_POOL_DUP_COUNT=1$'
echo "$bad_out" | rg -q -- '^E_CHAT_POOL_INVALID reason=invalid_url$'

ok_pool="$tmp/ok_pool.txt"
cat >"$ok_pool" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312101
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312102
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312103
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312104
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312105
EOF

ok_out="$("$MGR" validate --chat-pool-file "$ok_pool" --min 5)"
echo "$ok_out" | rg -q -- '^CHAT_POOL_OK=1$'
echo "$ok_out" | rg -q -- '^CHAT_POOL_COUNT=5$'
echo "$ok_out" | rg -q -- '^CHAT_POOL_INVALID_COUNT=0$'
echo "$ok_out" | rg -q -- '^CHAT_POOL_DUP_COUNT=0$'
echo "$ok_out" | rg -q -- '^CHAT_POOL_MIN_REQUIRED=5$'

echo "OK"
