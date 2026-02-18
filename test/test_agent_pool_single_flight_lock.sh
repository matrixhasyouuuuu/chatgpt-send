#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
pool_pid=""
cleanup() {
  if [[ -n "${pool_pid:-}" ]]; then
    kill "$pool_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

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
sleep 4
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: single-flight lock test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: single-flight lock test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Lock test task A
Lock test task B
EOF

lock_file="$tmp/pool.lock"
out1_file="$tmp/pool1.out"
(
  POOL_MODE=mock \
  POOL_LOCK_FILE="$lock_file" \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 2 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$tmp/pool_run_1" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" >"$out1_file" 2>&1
) &
pool_pid=$!

sleep 0.7

set +e
out2="$(
  POOL_MODE=mock \
  POOL_LOCK_FILE="$lock_file" \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 1 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$tmp/pool_run_2" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"
rc2=$?
set -e

[[ "$rc2" == "2" ]]
rg -q -- 'E_POOL_ALREADY_RUNNING lock_file=' <<<"$out2"

wait "$pool_pid"
pool_pid=""
rg -q -- '^POOL_STATUS=OK$' "$out1_file"

echo "OK"
