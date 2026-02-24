#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
mkdir -p "$proj"

fake_codex="$tmp/fake_codex"
cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-last-message) out="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null || true
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: agent pool follow mock done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: agent pool follow mock done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Pool follow diagnostics A
Pool follow diagnostics B
Pool follow diagnostics C
Pool follow diagnostics D
Pool follow diagnostics E
EOF

chat_pool_file="$tmp/chat_pool.txt"
cat >"$chat_pool_file" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312a01
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312a02
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312a03
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312a04
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312a05
EOF

pool_dir="$tmp/pool_run"
out="$(
  POOL_MODE=mock \
  POOL_FOLLOW=1 \
  POOL_FOLLOW_MODE=log \
  POOL_FOLLOW_TICK_MS=100 \
  POOL_FOLLOW_NO_ANSI=1 \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --chat-pool-file "$chat_pool_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
echo "$out" | rg -q -- '^POOL_FOLLOW=1$'
echo "$out" | rg -q -- '^POOL_FOLLOW_MODE=log$'
echo "$out" | rg -q -- '^POOL_FOLLOW_MODE_CONFIG=log$'
echo "$out" | rg -q -- '^POOL_FOLLOW_REASON=forced$'

follow_log="$(echo "$out" | sed -n 's/^POOL_FOLLOW_LOG=//p' | tail -n 1)"
follow_pid_file="$(echo "$out" | sed -n 's/^POOL_FOLLOW_PID_FILE=//p' | tail -n 1)"
test -n "$follow_log"
test -s "$follow_log"
rg -q -- '^PROGRESS ' "$follow_log"
rg -q -- '^FLEET_FOLLOW_DONE ' "$follow_log"

if [[ -n "$follow_pid_file" ]]; then
  if [[ -f "$follow_pid_file" ]]; then
    pid="$(tr -d '[:space:]' <"$follow_pid_file" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      echo "follow process still alive: $pid" >&2
      exit 1
    fi
  fi
fi

echo "OK"
