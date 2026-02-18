#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT_DIR/bin/spawn_second_agent"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
log_dir="$tmp/logs"
mkdir -p "$proj" "$log_dir"

fake_codex="$tmp/fake_codex"
cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-last-message) out="${2:-}"; shift 2;;
    *) shift;;
  esac
done
cat >/dev/null || true
sleep 0.15
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: parallel mock transport done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: parallel mock transport done'
exit 0
EOF
chmod +x "$fake_codex"

launch_child() {
  local idx="$1"
  CHATGPT_SEND_TRANSPORT=mock \
  CHATGPT_SEND_MOCK_CHAT_URL="https://chatgpt.com/c/abcd-1234" \
  CHATGPT_SEND_MOCK_REPLY="MOCK_REPLY_OK" \
  CHATGPT_SEND_MAX_CDP_SLOTS=1 \
  CHATGPT_SEND_SLOT_WAIT_TIMEOUT_SEC=30 \
  "$SPAWN" \
    --project-path "$proj" \
    --task "Parallel mock child #$idx" \
    --iterations 1 \
    --launcher direct \
    --timeout-sec 120 \
    --log-dir "$log_dir" \
    --cdp-port 9333 \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
}

out1="$(launch_child 1)"
out2="$(launch_child 2)"

exit1="$(echo "$out1" | sed -n 's/^EXIT_FILE=//p' | head -n 1)"
exit2="$(echo "$out2" | sed -n 's/^EXIT_FILE=//p' | head -n 1)"
log1="$(echo "$out1" | sed -n 's/^LOG_FILE=//p' | head -n 1)"
log2="$(echo "$out2" | sed -n 's/^LOG_FILE=//p' | head -n 1)"
res1="$(echo "$out1" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
res2="$(echo "$out2" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
chat_log_dir1="$(echo "$out1" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
chat_log_dir2="$(echo "$out2" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
transport_log1="$chat_log_dir1/transport.log"
transport_log2="$chat_log_dir2/transport.log"

wait_for_file() {
  local path="$1"
  local deadline=$(( $(date +%s) + 90 ))
  while [[ ! -f "$path" ]]; do
    if (( $(date +%s) >= deadline )); then
      echo "timeout waiting for $path" >&2
      exit 1
    fi
    sleep 0.2
  done
}

wait_for_file "$exit1"
wait_for_file "$exit2"

[[ "$(tr -d '[:space:]' <"$exit1")" == "0" ]]
[[ "$(tr -d '[:space:]' <"$exit2")" == "0" ]]

test -s "$res1"
test -s "$res2"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$res1"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$res2"

[[ -d "$chat_log_dir1" ]]
[[ -d "$chat_log_dir2" ]]
test -s "$transport_log1"
test -s "$transport_log2"
rg -q -- '\[P1\] transport=mock' "$transport_log1"
rg -q -- '\[P1\] transport=mock' "$transport_log2"

if rg -n -- 'E_SLOT_ACQUIRE_TIMEOUT' "$log1" "$log2" >/dev/null; then
  echo "unexpected slot acquire timeout in parallel mock run" >&2
  exit 1
fi

if rg -n -- 'json/version|9222|remote-debugging|\[cdp_chatgpt\]|CDP is not reachable|CDP_PREFLIGHT' "$transport_log1" "$transport_log2" >/dev/null; then
  echo "unexpected CDP markers in parallel mock transport logs" >&2
  exit 1
fi

example_log="$transport_log1"
if [[ -n "${example_log:-}" ]]; then
  sed -n '1,60p' "$example_log"
fi

echo "OK"
