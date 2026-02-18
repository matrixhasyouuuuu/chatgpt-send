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
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: e2e mock transport done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: e2e mock transport done'
exit 0
EOF
chmod +x "$fake_codex"

out="$(
  CHATGPT_SEND_TRANSPORT=mock \
  CHATGPT_SEND_MOCK_CHAT_URL="https://chatgpt.com/c/abcd-1234" \
  CHATGPT_SEND_MOCK_REPLY="MOCK_REPLY_OK" \
  "$SPAWN" \
    --project-path "$proj" \
    --task "E2E mock transport single child" \
    --iterations 1 \
    --launcher direct \
    --wait \
    --timeout-sec 60 \
    --log-dir "$log_dir" \
    --cdp-port 9333 \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

echo "$out" | rg -q -- '^CHILD_STATUS=0$'
echo "$out" | rg -q -- '^BROWSER_POLICY=optional$'

run_dir="$(echo "$out" | sed -n 's/^CHILD_RUN_DIR=//p' | head -n 1)"
child_result_json="$(echo "$out" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
chatgpt_log_dir="$(echo "$out" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
transport_log="$chatgpt_log_dir/transport.log"

[[ -d "$run_dir" ]]
[[ -d "$chatgpt_log_dir" ]]
test -s "$transport_log"
test -s "$child_result_json"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$child_result_json"

rg -q -- '\[P1\] transport=mock' "$transport_log"
if rg -n -- 'json/version|9222|remote-debugging|\[cdp_chatgpt\]|CDP is not reachable|CDP_PREFLIGHT' "$transport_log" >/dev/null; then
  echo "unexpected CDP markers inside mock transport logs" >&2
  exit 1
fi

# Print a short evidence fragment for higher-level gate/tests.
rg -n -- '\[P1\] transport=mock|\[mock\] |WORK_CHAT|RECOVERY_START|ITER_RESULT' "$transport_log" | sed -n '1,40p'
echo "OK"
