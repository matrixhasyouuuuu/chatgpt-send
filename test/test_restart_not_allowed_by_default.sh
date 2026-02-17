#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/state"

target_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
printf '%s\n' "$target_url" >"$root/state/work_chat_url.txt"

set +e
out="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  "$SCRIPT" --graceful-restart-browser --chatgpt-url "$target_url" 2>&1
)"
st=$?
set -e

[[ "$st" -eq 79 ]]
echo "$out" | rg -q -- 'E_RESTART_NOT_ALLOWED'

echo "OK"
