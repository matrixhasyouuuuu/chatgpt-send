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
echo "$out" | rg -q -- '"profile_size_kb": '
echo "$out" | rg -q -- '"chrome_uptime_s": '
echo "$out" | rg -q -- '"recoveries_in_run": '
echo "$out" | rg -q -- '"restart_recommended": '
rg -q -- 'DOCTOR done invariants_ok=1' "$tmp/doctor_pos.err"

# Health recommendation case: if uptime threshold is 0 and recoveries were seen,
# doctor must recommend restart.
mkdir -p "$root/state/runs/run-health-sample/logs"
printf '%s\n' "E_CDP_TIMEOUT_RETRY attempt=1" >"$root/state/runs/run-health-sample/logs/sample.log"
out_health="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  CHATGPT_SEND_RESTART_RECOMMEND_UPTIME_SEC=0 \
  "$SCRIPT" --doctor --json 2>"$tmp/doctor_health.err"
)"
echo "$out_health" | rg -q -- '"recoveries_in_run": 1'
echo "$out_health" | rg -q -- '"restart_recommended": 1'

# Negative case: force/protect mismatch should fail in strict doctor mode.
set +e
out_bad="$(
  CHATGPT_SEND_ROOT="$root" \
  CHATGPT_SEND_PROFILE_DIR="$root/state/manual-login-profile" \
  CHATGPT_SEND_PROTECT_CHAT_URL="https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
  CHATGPT_SEND_FORCE_CHAT_URL="https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" \
  CHATGPT_SEND_STRICT_DOCTOR=1 \
  "$SCRIPT" --doctor --json 2>&1
)"
st_bad=$?
set -e
[[ "$st_bad" -ne 0 ]]
echo "$out_bad" | rg -q -- 'E_DOCTOR_INVARIANT_FAIL'

echo "OK"
