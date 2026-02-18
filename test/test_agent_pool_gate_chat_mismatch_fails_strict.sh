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
  printf '%s\n' 'CHILD_RESULT: strict chat proof test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: strict chat proof test done'
EOF
chmod +x "$fake_codex"

fake_monitor="$tmp/fake_monitor.sh"
cat >"$fake_monitor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
summary_json=""
summary_csv=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary-json) summary_json="${2:-}"; shift 2 ;;
    --summary-csv) summary_csv="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >"$summary_json" <<'JSON'
{
  "total": 1,
  "done": 1,
  "failed": 0,
  "running": 0,
  "pending": 0,
  "done_ok": 1,
  "done_fail": 0,
  "stuck": 0,
  "orphaned": 0,
  "unknown": 0,
  "disk_status": "ok",
  "discovery_sources": {"registry": 0, "roster": 1, "merged": 1},
  "missing_artifacts_total": 0,
  "chat_ok_total": 0,
  "chat_mismatch_total": 1,
  "chat_unknown_total": 0,
  "agents": []
}
JSON
printf 'agent_id,run_id,state_class\n' >"$summary_csv"
exit 0
EOF
chmod +x "$fake_monitor"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Strict gate task A
EOF

set +e
out="$(
  POOL_MODE=mock \
  POOL_FLEET_MONITOR_ENABLED=0 \
  POOL_FLEET_GATE_ENABLED=1 \
  POOL_STRICT_CHAT_PROOF=1 \
  POOL_FLEET_MONITOR_SCRIPT="$fake_monitor" \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 1 \
    --iterations 1 \
    --retry-max 0 \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"
rc=$?
set -e

[[ "$rc" == "1" ]]
echo "$out" | rg -q -- '^POOL_STATUS=FAILED$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_STATUS=FAIL$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_REASON=chat_mismatch$'
echo "$out" | rg -q -- '^POOL_STRICT_CHAT_PROOF=1$'
echo "$out" | rg -q -- '^POOL_CHAT_MISMATCH_TOTAL=1$'

echo "OK"
