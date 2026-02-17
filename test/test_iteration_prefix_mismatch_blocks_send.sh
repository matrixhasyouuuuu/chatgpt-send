#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/state"

cat >"$root/state/chats.json" <<'EOF'
{
  "active": "spec",
  "chats": {
    "spec": {
      "url": "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "loop_done": 4,
      "loop_max": 40
    }
  }
}
EOF

export CHATGPT_SEND_ROOT="$root"
export CHATGPT_SEND_ENFORCE_ITERATION_PREFIX=1

set +e
out="$("$SCRIPT" \
  --chatgpt-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
  --prompt "Iteration 8/40 request.

Mismatch demo." 2>&1)"
st=$?
set -e

[[ "$st" -eq 82 ]]
echo "$out" | rg -q -- 'E_ITERATION_PREFIX_MISMATCH'
if echo "$out" | rg -q -- 'SEND_START|action=send'; then
  echo "unexpected send pipeline start on iteration mismatch" >&2
  exit 1
fi

echo "OK"
