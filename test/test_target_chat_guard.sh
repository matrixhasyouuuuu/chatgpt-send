#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CHATGPT_SEND_ROOT="$tmp"
export CHATGPT_SEND_CDP_PORT="59997"
mkdir -p "$tmp/docs" "$tmp/state"
printf '%s\n' "bootstrap" >"$tmp/docs/specialist_bootstrap.txt"

# Case 1: sending to home must be blocked by default.
set +e
out_home="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/" --prompt "must fail home" 2>&1)"
st_home=$?
set -e
[[ "$st_home" -eq 72 ]]
echo "$out_home" | rg -q -- 'E_TARGET_CHAT_REQUIRED'

# Case 2: active session URL and pinned URL mismatch must block sends.
cat >"$tmp/state/chats.json" <<'EOF'
{"active":"work","chats":{"work":{"url":"https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}}
EOF
printf '%s\n' "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" >"$tmp/state/chatgpt_url.txt"

set +e
out_mismatch="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" --prompt "must fail mismatch" 2>&1)"
st_mismatch=$?
set -e
[[ "$st_mismatch" -eq 72 ]]
echo "$out_mismatch" | rg -q -- 'E_CHAT_STATE_MISMATCH'

echo "OK"
