#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
mutator_pid=""
cleanup() {
  if [[ -n "${mutator_pid:-}" ]]; then
    kill "$mutator_pid" >/dev/null 2>&1 || true
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
sleep 1
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: early abort retry test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: early abort retry test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Early retry A
Early retry B
Early retry C
EOF

chat_pool_file="$tmp/chat_pool.txt"
cat >"$chat_pool_file" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312e01
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312e02
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312e03
EOF

pool_dir="$tmp/pool_run"
(
  # Inject "stuck" only at startup so first attempt is aborted early.
  for _ in $(seq 1 120); do
    summary="$pool_dir/fleet.summary.json"
    if [[ -f "$summary" ]]; then
      cat >"$summary" <<'JSON'
{
  "total": 3,
  "done_ok": 0,
  "done_fail": 0,
  "running": 2,
  "stuck": 1,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "chat_ok_total": 0,
  "chat_mismatch_total": 0,
  "chat_unknown_total": 0,
  "agents": [
    {"agent_id":"1","state_class":"STUCK"},
    {"agent_id":"2","state_class":"RUNNING"},
    {"agent_id":"3","state_class":"RUNNING"}
  ]
}
JSON
      break
    fi
    sleep 0.05
  done
) &
mutator_pid="$!"

out="$(
  POOL_MODE=mock \
  POOL_FOLLOW=0 \
  POOL_EARLY_GATE=1 \
  POOL_EARLY_GATE_TICK_SEC=1 \
  POOL_EARLY_GATE_ACTION=abort_and_retry \
  POOL_EARLY_GATE_STUCK_FAIL=1 \
  POOL_EARLY_GATE_RETRYABLE_CLASSES=STUCK,ORPHANED,DONE_FAIL \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --chat-pool-file "$chat_pool_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 1 \
    --timeout-sec 12 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

kill "$mutator_pid" >/dev/null 2>&1 || true
mutator_pid=""

echo "$out" | rg -q -- 'EARLY_GATE_TRIGGER'
echo "$out" | rg -q -- 'RETRY_PHASE_START source=early_gate'
echo "$out" | rg -q -- 'RETRY_PHASE_DONE source=early_gate'
echo "$out" | rg -q -- '^POOL_STATUS=OK$'

echo "OK"

