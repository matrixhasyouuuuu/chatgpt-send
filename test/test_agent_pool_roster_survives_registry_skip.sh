#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
registry_lock_pid=""
cleanup() {
  if [[ -n "${registry_lock_pid:-}" ]]; then
    kill "$registry_lock_pid" >/dev/null 2>&1 || true
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
  printf '%s\n' 'CHILD_RESULT: registry skip test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: registry skip test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Registry skip task A
Registry skip task B
EOF

pool_dir="$tmp/pool_run"
mkdir -p "$pool_dir"
registry_lock="$pool_dir/fleet_registry.jsonl.lock"
(
  exec 9>"$registry_lock"
  flock -n 9
  sleep 40
) &
registry_lock_pid=$!
sleep 0.2

set +e
out="$(
  POOL_MODE=mock \
  POOL_FLEET_REGISTRY_LOCK_TIMEOUT_SEC=0 \
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

[[ "$rc" == "0" ]]
echo "$out" | rg -q -- '^POOL_STATUS=OK$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_STATUS=PASS$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_REASON=ok$'
echo "$out" | rg -q -- '^POOL_FLEET_GATE_OBSERVED_TOTAL=2$'

registry_file="$(echo "$out" | sed -n 's/^POOL_FLEET_REGISTRY=//p' | tail -n 1)"
roster_file="$(echo "$out" | sed -n 's/^POOL_FLEET_ROSTER_JSONL=//p' | tail -n 1)"
fleet_summary_json="$(echo "$out" | sed -n 's/^POOL_FLEET_SUMMARY_JSON=//p' | tail -n 1)"

test -s "$roster_file"
test -s "$fleet_summary_json"
[[ "$(wc -l <"$registry_file" | tr -d '[:space:]')" == "0" ]]
[[ "$(wc -l <"$roster_file" | tr -d '[:space:]')" == "2" ]]

python3 - "$fleet_summary_json" <<'PY'
import json
import pathlib
import sys

obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
sources = obj.get("discovery_sources") or {}
if sources.get("registry") != 0:
    raise SystemExit(f"expected discovery_sources.registry=0, got {sources.get('registry')}")
if sources.get("roster") != 2:
    raise SystemExit(f"expected discovery_sources.roster=2, got {sources.get('roster')}")
if sources.get("merged") != 2:
    raise SystemExit(f"expected discovery_sources.merged=2, got {sources.get('merged')}")
if obj.get("missing_artifacts_total") != 0:
    raise SystemExit(f"expected missing_artifacts_total=0, got {obj.get('missing_artifacts_total')}")
PY

echo "OK"
