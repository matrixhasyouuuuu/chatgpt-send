#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
registry_lock_pid=""
roster_lock_pid=""
cleanup() {
  if [[ -n "${registry_lock_pid:-}" ]]; then
    kill "$registry_lock_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${roster_lock_pid:-}" ]]; then
    kill "$roster_lock_pid" >/dev/null 2>&1 || true
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
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: fleet incomplete test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: fleet incomplete test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Fleet incomplete task A
Fleet incomplete task B
EOF

pool_dir="$tmp/pool_run"
mkdir -p "$pool_dir"

registry_lock="$pool_dir/fleet_registry.jsonl.lock"
roster_lock="$pool_dir/fleet_roster.jsonl.lock"
(
  exec 9>"$registry_lock"
  flock -n 9
  sleep 40
) &
registry_lock_pid=$!
(
  exec 8>"$roster_lock"
  flock -n 8
  sleep 40
) &
roster_lock_pid=$!
sleep 0.2

set +e
out="$(
  POOL_MODE=mock \
  POOL_FLEET_REGISTRY_LOCK_TIMEOUT_SEC=0 \
  POOL_FLEET_ROSTER_LOCK_TIMEOUT_SEC=0 \
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
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"
rc=$?
set -e

[[ "$rc" == "1" ]]
echo "$out" | rg -q -- '^POOL_STATUS=FAILED$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_STATUS=FAIL$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_REASON=fleet_incomplete$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_EXPECTED_TOTAL=2$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_OBSERVED_TOTAL=0$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_MISSING_ARTIFACTS_TOTAL=0$'

registry_file="$(echo "$out" | sed -n 's/^POOL_FLEET_REGISTRY=//p' | tail -n 1)"
roster_file="$(echo "$out" | sed -n 's/^POOL_FLEET_ROSTER_JSONL=//p' | tail -n 1)"
[[ "$(wc -l <"$registry_file" | tr -d '[:space:]')" == "0" ]]
[[ "$(wc -l <"$roster_file" | tr -d '[:space:]')" == "0" ]]

echo "OK"
