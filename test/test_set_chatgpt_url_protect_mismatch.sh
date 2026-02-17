#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/docs" "$tmp/state"
printf '%s\n' "bootstrap" >"$tmp/docs/specialist_bootstrap.txt"

protected_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
other_url="https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

set +e
out_bad="$(
  CHATGPT_SEND_ROOT="$tmp" \
  CHATGPT_SEND_PROTECT_CHAT_URL="$protected_url" \
  "$SCRIPT" --set-chatgpt-url "$other_url" 2>&1
)"
st_bad=$?
set -e
[[ "$st_bad" -eq 78 ]]
echo "$out_bad" | rg -q -- 'E_PROTECT_CHAT_MISMATCH'

out_ok="$(
  CHATGPT_SEND_ROOT="$tmp" \
  CHATGPT_SEND_PROTECT_CHAT_URL="$protected_url" \
  "$SCRIPT" --set-chatgpt-url "$protected_url" 2>&1
)"
echo "$out_ok" | rg -q -- 'Saved default ChatGPT URL'

[[ "$(cat "$tmp/state/chatgpt_url.txt")" == "$protected_url" ]]
[[ "$(cat "$tmp/state/work_chat_url.txt")" == "$protected_url" ]]

echo "OK"
