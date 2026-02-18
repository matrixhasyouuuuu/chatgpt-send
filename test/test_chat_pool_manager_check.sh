#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGR="$ROOT_DIR/scripts/chat_pool_manager.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pool="$tmp/pool.txt"
out_init="$("$MGR" init --size 2 --out "$pool")"
echo "$out_init" | rg -q -- '^POOL_INIT_OK=1$'
echo "$out_init" | rg -q -- "^POOL_FILE=$pool$"

url1="https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4313111"
url2="https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4313222"

out_add1="$("$MGR" add --url "$url1" --file "$pool")"
echo "$out_add1" | rg -q -- '^POOL_ADD_OK=1$'
echo "$out_add1" | rg -q -- '^POOL_ADD_DUP=0$'

out_add2="$("$MGR" add --url "$url2" --file "$pool")"
echo "$out_add2" | rg -q -- '^POOL_ADD_OK=1$'
echo "$out_add2" | rg -q -- '^POOL_ADD_DUP=0$'

out_add_dup="$("$MGR" add --url "$url2" --file "$pool")"
echo "$out_add_dup" | rg -q -- '^POOL_ADD_OK=1$'
echo "$out_add_dup" | rg -q -- '^POOL_ADD_DUP=1$'

out_check="$("$MGR" check --file "$pool" --size 2)"
echo "$out_check" | rg -q -- '^POOL_CHECK_OK=1$'
echo "$out_check" | rg -q -- '^POOL_TOTAL=2$'
echo "$out_check" | rg -q -- '^POOL_BAD_COUNT=0$'
echo "$out_check" | rg -q -- '^POOL_DUP_COUNT=0$'

bad="$tmp/bad_pool.txt"
cat >"$bad" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4313001
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4313001
https://chatgpt.com/not-a-conversation
EOF

set +e
bad_out="$("$MGR" check --file "$bad" --size 2 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" != "0" ]]
echo "$bad_out" | rg -q -- '^POOL_CHECK_OK=0$'
echo "$bad_out" | rg -q -- '^POOL_BAD_COUNT=1$'
echo "$bad_out" | rg -q -- '^POOL_DUP_COUNT=1$'

echo "OK"
