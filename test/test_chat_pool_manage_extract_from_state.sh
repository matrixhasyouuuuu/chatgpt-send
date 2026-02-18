#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGR="$ROOT_DIR/scripts/chat_pool_manage.sh"
FIXTURE="$ROOT_DIR/test/fixtures/chats.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out_pool="$tmp/chat_pool.txt"
extract_out="$("$MGR" extract --state-chats "$FIXTURE" --out "$out_pool" --count 5 --exclude-url "https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4311001")"
echo "$extract_out" | rg -q -- '^CHAT_POOL_WRITTEN=5$'
echo "$extract_out" | rg -q -- "^CHAT_POOL_FILE=$out_pool$"
echo "$extract_out" | rg -q -- '^CHAT_POOL_REQUESTED=5$'
echo "$extract_out" | rg -q -- '^CHAT_POOL_FOUND=5$'

mapfile -t urls < <(sed -e 's/\r$//' "$out_pool" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
[[ "${#urls[@]}" == "5" ]]
if printf '%s\n' "${urls[@]}" | rg -q -- '6994c413-7cb4-8388-81a3-1d6ee4311001'; then
  echo "exclude-url still present" >&2
  exit 1
fi

validate_out="$("$MGR" validate --chat-pool-file "$out_pool" --min 5)"
echo "$validate_out" | rg -q -- '^CHAT_POOL_OK=1$'
echo "$validate_out" | rg -q -- '^CHAT_POOL_COUNT=5$'

echo "OK"
