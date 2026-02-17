#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CHATGPT_SEND_ROOT="$tmp"
export CHATGPT_SEND_CDP_PORT="59999"

mkdir -p "$tmp/docs" "$tmp/state"
printf '%s\n' "placeholder" >"$tmp/docs/placeholder.txt"
printf '%s\n' "bootstrap" >"$tmp/docs/specialist_bootstrap.txt"

out="$("$SCRIPT" --list-chats)"
if [[ "$out" != "No saved Specialist sessions."* ]]; then
  echo "expected empty list, got: $out" >&2
  exit 1
fi

# Invalid conversation URL should be rejected.
set +e
"$SCRIPT" --set-chatgpt-url "https://chatgpt.com/c/test-loop" >/dev/null 2>&1
st=$?
set -e
if [[ $st -eq 0 ]]; then
  echo "expected non-zero for invalid /c/ URL" >&2
  exit 1
fi

# Set a valid conversation URL and ensure it appears as `last`.
valid_url="https://chatgpt.com/c/69921c99-3964-838a-9b8f-d0e40620cf04"
"$SCRIPT" --set-chatgpt-url "$valid_url" >/dev/null
work_url="$(cat "$tmp/state/work_chat_url.txt" | head -n 1)"
if [[ "$work_url" != "$valid_url" ]]; then
  echo "expected work_chat_url=$valid_url, got: $work_url" >&2
  exit 1
fi

out="$("$SCRIPT" --list-chats)"
echo "$out" | rg -q -- "last"

out="$("$SCRIPT" --doctor)"
echo "$out" | rg -q -- "chatgpt_send doctor"

# Save another session name and switch by index.
alpha_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
"$SCRIPT" --chatgpt-url "$alpha_url" --save-chat alpha >/dev/null
"$SCRIPT" --use-chat 1 >/dev/null

# show-chatgpt-url should prefer persisted work chat over explicit arg.
shown="$("$SCRIPT" --chatgpt-url "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" --show-chatgpt-url)"
if [[ "$shown" != "$alpha_url" ]]; then
  echo "expected shown work chat=$alpha_url, got: $shown" >&2
  exit 1
fi

pinned="$(cat "$tmp/state/chatgpt_url.txt" | head -n 1)"
if [[ "$pinned" != "$alpha_url" ]]; then
  echo "expected pinned=$alpha_url, got: $pinned" >&2
  exit 1
fi

# protect must block re-pointing to another chat.
set +e
protect_out="$(CHATGPT_SEND_PROTECT_CHAT_URL="$alpha_url" "$SCRIPT" --set-chatgpt-url "$valid_url" 2>&1)"
protect_st=$?
set -e
if [[ "$protect_st" -eq 0 ]]; then
  echo "expected non-zero when protect mismatches" >&2
  exit 1
fi
echo "$protect_out" | rg -q -- "E_PROTECT_CHAT_MISMATCH"

# Loop state should attach to active session and be mutable.
"$SCRIPT" --loop-init 3 >/dev/null
("$SCRIPT" --loop-status | rg -q -- "Loop: 0/3") || exit 1

"$SCRIPT" --loop-inc >/dev/null
("$SCRIPT" --loop-status | rg -q -- "Loop: 1/3") || exit 1

"$SCRIPT" --loop-clear >/dev/null
("$SCRIPT" --loop-status | rg -q -- "Loop: \\(not set\\)") || exit 1

echo "OK"
