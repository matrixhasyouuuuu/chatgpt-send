#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CHATGPT_SEND_ROOT="$tmp"
export CHATGPT_SEND_CDP_PORT="59998"
export CHATGPT_SEND_WAIT_ONLY="1"

mkdir -p "$tmp/docs" "$tmp/state"
printf '%s\n' "bootstrap" >"$tmp/docs/specialist_bootstrap.txt"

set +e
out_prompt="$("$SCRIPT" --prompt "must_not_send" 2>&1)"
st_prompt=$?
set -e
[[ "$st_prompt" -eq 74 ]]
echo "$out_prompt" | rg -q -- 'E_USER_REQUEST_WAIT_ONLY action=prompt_send'

set +e
out_open="$("$SCRIPT" --open-browser 2>&1)"
st_open=$?
set -e
[[ "$st_open" -eq 74 ]]
echo "$out_open" | rg -q -- 'E_USER_REQUEST_WAIT_ONLY action=open_browser'

out_list="$("$SCRIPT" --list-chats)"
echo "$out_list" | rg -q -- '^No saved Specialist sessions\.'

echo "OK"
