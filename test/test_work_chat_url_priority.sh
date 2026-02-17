#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/docs" "$tmp/state"
printf '%s\n' "bootstrap" >"$tmp/docs/specialist_bootstrap.txt"

work_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
pinned_url="https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

printf '%s\n' "$pinned_url" >"$tmp/state/chatgpt_url.txt"
printf '%s\n' "$work_url" >"$tmp/state/work_chat_url.txt"

out="$(
  CHATGPT_SEND_ROOT="$tmp" \
  "$SCRIPT" --show-chatgpt-url
)"
[[ "$out" == "$work_url" ]]

echo "OK"
