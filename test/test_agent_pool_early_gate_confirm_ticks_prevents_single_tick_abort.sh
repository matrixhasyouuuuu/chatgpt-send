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
sleep 2
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: confirm ticks single tick test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: confirm ticks single tick test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Confirm single tick A
Confirm single tick B
Confirm single tick C
EOF

chat_pool_file="$tmp/chat_pool.txt"
cat >"$chat_pool_file" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f01
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f02
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f03
EOF

pool_dir="$tmp/pool_run"
mkdir -p "$pool_dir"
cat >"$pool_dir/fleet.summary.json" <<'JSON'
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

(
  # Keep summary healthy before the second tick so confirm_ticks=2 does not trigger abort.
  sleep 0.2
  for _ in $(seq 1 40); do
    cat >"$pool_dir/fleet.summary.json" <<'JSON'
{
  "total": 3,
  "done_ok": 0,
  "done_fail": 0,
  "running": 3,
  "stuck": 0,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "chat_ok_total": 0,
  "chat_mismatch_total": 0,
  "chat_unknown_total": 0,
  "agents": [
    {"agent_id":"1","state_class":"RUNNING"},
    {"agent_id":"2","state_class":"RUNNING"},
    {"agent_id":"3","state_class":"RUNNING"}
  ]
}
JSON
    sleep 0.1
  done
) &
mutator_pid="$!"

out="$(
  POOL_MODE=mock \
  POOL_FOLLOW=0 \
  POOL_EARLY_GATE=1 \
  POOL_EARLY_GATE_TICK_SEC=1 \
  POOL_EARLY_GATE_CONFIRM_TICKS=2 \
  POOL_EARLY_GATE_ACTION=abort \
  POOL_EARLY_GATE_STUCK_FAIL=1 \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --chat-pool-file "$chat_pool_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 0 \
    --timeout-sec 12 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

kill "$mutator_pid" >/dev/null 2>&1 || true
mutator_pid=""

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
if echo "$out" | rg -q -- 'EARLY_GATE_TRIGGER'; then
  echo "unexpected EARLY_GATE_TRIGGER on single tick with confirm_ticks=2" >&2
  exit 1
fi
if [[ -f "$pool_dir/.early_abort" ]]; then
  echo "unexpected .early_abort marker on single tick with confirm_ticks=2" >&2
  exit 1
fi

echo "OK"
