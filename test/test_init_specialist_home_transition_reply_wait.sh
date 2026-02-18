#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/mock_specialist" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/bin" "$root/docs" "$root/state"

home_url="$(cat "$FIXTURES/home_url.txt")"
work_url="$(cat "$FIXTURES/work_url.txt")"
stale_url="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"
printf '%s\n' "$stale_url" >"$root/state/work_chat_url.txt"
printf '%s\n' "$stale_url" >"$root/state/chatgpt_url.txt"
printf '%s\n%s\n%s\n' "$home_url" "$work_url" "$work_url" >"$tmp/mock_chat_urls.txt"

mkdir -p "$tmp/mock_replies"
cp "$FIXTURES/replies/001_bootstrap.txt" "$tmp/mock_replies/001_bootstrap.txt"
cp "$FIXTURES/replies/002_ack.txt" "$tmp/mock_replies/002_ack.txt"

export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_TRANSPORT=mock
export CHATGPT_SEND_MOCK_CHAT_URL_FILE="$tmp/mock_chat_urls.txt"
export CHATGPT_SEND_MOCK_REPLIES_DIR="$tmp/mock_replies"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_MAX_SEC=10
export CHATGPT_SEND_REPLY_POLL_MS=200
export CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS=3000
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=0

out="$("$SCRIPT" --init-specialist --topic "new session transition" 2>&1)"

echo "$out" | rg -q -- '^\[P1\] transport=mock$'
echo "$out" | rg -q -- '\[mock\] open_browser skipped url=https://chatgpt.com/'
echo "$out" | rg -q -- "\[mock\] capture_chat_url url=${home_url}"
echo "$out" | rg -q -- "\[mock\] capture_chat_url url=${work_url}"
echo "$out" | rg -q -- 'CHAT_ROUTE_UPDATE reason=init_specialist_home_to_conversation'
echo "$out" | rg -q -- 'REPLY_WAIT route_recovered reason=init_specialist_home_transition'
echo "$out" | rg -q -- 'ITER_RESULT outcome=PASS'
if echo "$out" | rg -q -- '\[cdp_chatgpt\]|/json/version'; then
  echo "unexpected CDP markers in mock transport run" >&2
  exit 1
fi

[[ "$(cat "$root/state/work_chat_url.txt")" == "$work_url" ]]
[[ -s "$root/state/mock_last_prompt.txt" ]]
rg -q -- 'new session transition' "$root/state/mock_last_prompt.txt"

printf '%s\n' "$out" | rg -- '\[P1\] transport=mock|\[mock\] capture_chat_url|CHAT_ROUTE_UPDATE reason=init_specialist_home_to_conversation|REPLY_WAIT route_recovered' | sed -n '1,20p'
echo "OK"
