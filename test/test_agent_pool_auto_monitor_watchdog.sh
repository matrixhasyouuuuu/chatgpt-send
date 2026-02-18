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
sleep 6
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: pool watchdog test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: pool watchdog test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Watchdog task A
Watchdog task B
EOF

pool_dir="$tmp/pool_run"
out_file="$tmp/pool.out"

(
  POOL_MODE=mock \
  POOL_FLEET_MONITOR_HEARTBEAT_SEC=1 \
  POOL_FLEET_WATCHDOG_COOLDOWN_SEC=1 \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 2 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" >"$out_file" 2>&1
) &
pool_pid=$!

monitor_pid_file="$pool_dir/fleet.monitor.pid"
deadline=$(( $(date +%s) + 20 ))
while [[ ! -s "$monitor_pid_file" ]]; do
  if ! kill -0 "$pool_pid" >/dev/null 2>&1; then
    echo "agent_pool_run exited before monitor pid appeared" >&2
    cat "$out_file" >&2 || true
    exit 1
  fi
  if (( $(date +%s) >= deadline )); then
    echo "timeout waiting for monitor pid file: $monitor_pid_file" >&2
    exit 1
  fi
  sleep 0.1
done

monitor_pid="$(tr -d '[:space:]' <"$monitor_pid_file")"
if [[ -n "$monitor_pid" ]]; then
  kill "$monitor_pid" >/dev/null 2>&1 || true
fi

wait "$pool_pid"
pool_pid=""

out="$(cat "$out_file")"
rg -q -- '^POOL_STATUS=OK$' <<<"$out"
rg -q -- '^POOL_FLEET_GATE_STATUS=PASS$' <<<"$out"

watchdog_restarts="$(echo "$out" | sed -n 's/^POOL_FLEET_WATCHDOG_RESTARTS=//p' | tail -n 1)"
[[ "$watchdog_restarts" =~ ^[0-9]+$ ]]
(( watchdog_restarts >= 1 ))

watchdog_log="$(echo "$out" | sed -n 's/^POOL_WATCHDOG_LOG=//p' | tail -n 1)"
test -s "$watchdog_log"
rg -q -- 'event=fleet_monitor_restarted' "$watchdog_log"

echo "OK"
