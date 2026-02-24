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
sleep 5
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: confirm ticks two tick test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: confirm ticks two tick test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Confirm two ticks A
Confirm two ticks B
Confirm two ticks C
EOF

chat_pool_file="$tmp/chat_pool.txt"
cat >"$chat_pool_file" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f11
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f12
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312f13
EOF

pool_dir="$tmp/pool_run"
mkdir -p "$pool_dir"

(
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
    {"agent_id":"1","run_id":"run-a1","state_class":"STUCK"},
    {"agent_id":"2","run_id":"run-a2","state_class":"RUNNING"},
    {"agent_id":"3","run_id":"run-a3","state_class":"RUNNING"}
  ]
}
JSON
    fi
    sleep 0.05
  done
) &
mutator_pid="$!"

set +e
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
rc=$?
set -e

kill "$mutator_pid" >/dev/null 2>&1 || true
mutator_pid=""

if [[ "$rc" == "0" ]]; then
  echo "expected non-zero rc on two-tick early abort trigger" >&2
  exit 1
fi
echo "$out" | rg -q -- 'EARLY_GATE_TRIGGER'
echo "$out" | rg -q -- '^POOL_STATUS=ABORTED_EARLY$'
echo "$out" | rg -q -- '^POOL_EARLY_ABORT_TRIGGERED=1$'
echo "$out" | rg -q -- '^POOL_EARLY_ABORT_IDS_COUNT=1$'
test -f "$pool_dir/.early_abort"
test -f "$pool_dir/.early_abort.ids"
test -f "$pool_dir/early_abort.meta.json"
rg -q -- 'confirm_ticks=2' "$pool_dir/.early_abort.reason"

echo "OK"
