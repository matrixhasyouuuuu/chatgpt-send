#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/state"
printf '%s\n' "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" >"$root/state/chatgpt_url.txt"

# Positive case: invariants must be OK and JSON must contain fields.
out="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  "$SCRIPT" --doctor --json 2>"$tmp/doctor_pos.err"
)"
echo "$out" | rg -q -- '"invariants_ok": 1'
echo "$out" | rg -q -- '"profile_dir_used": 1'
echo "$out" | rg -q -- '"force_chat_url_set": 0'
rg -q -- 'DOCTOR done invariants_ok=1' "$tmp/doctor_pos.err"

# Negative case: force == protect should fail in strict doctor mode.
set +e
out_bad="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  CHATGPT_SEND_PROTECT_CHAT_URL="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
  CHATGPT_SEND_FORCE_CHAT_URL="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
  CHATGPT_SEND_STRICT_DOCTOR=1 \
  "$SCRIPT" --doctor --json 2>&1
)"
st_bad=$?
set -e
[[ "$st_bad" -ne 0 ]]
echo "$out_bad" | rg -q -- 'E_DOCTOR_INVARIANT_FAIL'

echo "OK"
