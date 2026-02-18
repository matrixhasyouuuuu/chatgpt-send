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
stale_url="https://chatgpt.com/c/deadbeef-dead-beef-dead-beefdeadbeef"

printf '%s\n' "bootstrap" >"$root/docs/specialist_bootstrap.txt"
printf '%s\n' "$stale_url" >"$root/state/work_chat_url.txt"
printf '%s\n' "$stale_url" >"$root/state/chatgpt_url.txt"
printf '%s\n%s\n%s\n' "$home_url" "$work_url" "$work_url" >"$tmp/mock_chat_urls.txt"

mkdir -p "$tmp/mock_replies"
cp "$FIXTURES/replies/001_bootstrap.txt" "$tmp/mock_replies/001_bootstrap.txt"

export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_TRANSPORT=mock
export CHATGPT_SEND_MOCK_CHAT_URL_FILE="$tmp/mock_chat_urls.txt"
export CHATGPT_SEND_MOCK_REPLIES_DIR="$tmp/mock_replies"
export CHATGPT_SEND_REPLY_POLLING=1
export CHATGPT_SEND_REPLY_MAX_SEC=10
export CHATGPT_SEND_REPLY_POLL_MS=200
export CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS=3000
export CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY=0

out="$("$SCRIPT" --init-specialist --topic "new session topic" 2>&1)"

echo "$out" | rg -q -- '^\[P1\] transport=mock$'
echo "$out" | rg -q -- 'WORK_CHAT url=https://chatgpt.com/ chat_id=none source=explicit_arg'
echo "$out" | rg -q -- 'W_LEDGER_BYPASS_INIT_HOME'
echo "$out" | rg -q -- "\[mock\] capture_chat_url url=${home_url}"
echo "$out" | rg -q -- "\[mock\] capture_chat_url url=${work_url}"
if echo "$out" | rg -q -- 'CHAT_ROUTE=E_ROUTE_MISMATCH'; then
  echo "unexpected route mismatch in init-specialist mock flow" >&2
  exit 1
fi
if echo "$out" | rg -q -- '\[cdp_chatgpt\]|/json/version'; then
  echo "unexpected CDP markers in mock transport run" >&2
  exit 1
fi
echo "$out" | rg -q -- 'ITER_RESULT outcome=PASS'

[[ "$(cat "$root/state/work_chat_url.txt")" == "$work_url" ]]

printf '%s\n' "$out" | rg -- '\[P1\] transport=mock|\[mock\] capture_chat_url|WORK_CHAT url=https://chatgpt.com/|W_LEDGER_BYPASS_INIT_HOME' | sed -n '1,20p'
echo "OK"
