#!/usr/bin/env bash
set -euo pipefail

SPAWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/spawn_second_agent"

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
  {
    echo "CHILD_FILES_TOUCHED: none"
    echo "CHILD_OVERLAP: none"
    echo "CHILD_CHECKS: none"
    echo "CHILD_RESULT: swarm prompt test OK"
  } >"$out"
fi
echo "CHILD_RESULT: swarm prompt test OK"
EOF
chmod +x "$fake_codex"

out="$("$SPAWN" \
  --project-path "$proj" \
  --task "Проверить только prompt/metadata для роевого режима" \
  --iterations 1 \
  --launcher direct \
  --wait \
  --timeout-sec 30 \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" \
  --browser-disabled \
  --agent-id "agent-2" \
  --agent-name "Борис" \
  --team-goal "Ускорить правки через рой child-агентов под контролем координатора" \
  --peer "agent-1 (Маша): делает патч в send pipeline" \
  --peer "agent-3 (Игорь): гоняет тесты и проверяет регрессии" 2>&1)"

echo "$out" | rg -q '^AGENT_ID=agent-2$'
echo "$out" | rg -q '^AGENT_NAME=Борис$'
echo "$out" | rg -q '^TEAM_GOAL=Ускорить правки через рой child-агентов под контролем координатора$'
echo "$out" | rg -q '^TEAM_PEERS_COUNT=2$'
echo "$out" | rg -q '^CHILD_STATUS=0$'
echo "$out" | rg -q '^CHILD_RESULT=CHILD_RESULT: swarm prompt test OK$'

run_dir="$(echo "$out" | sed -n 's/^CHILD_RUN_DIR=//p' | head -n 1)"
run_id="$(echo "$out" | sed -n 's/^RUN_ID=//p' | head -n 1)"
prompt_file="$run_dir/$run_id.prompt.txt"
[[ -f "$prompt_file" ]]

rg -q 'Child identity: agent-2 \(Борис\)' "$prompt_file"
rg -q 'Team goal \(shared\): Ускорить правки через рой child-агентов под контролем координатора' "$prompt_file"
rg -q 'Peer assignments \(swarm context\):' "$prompt_file"
rg -q 'agent-1 \(Маша\): делает патч в send pipeline' "$prompt_file"
rg -q 'agent-3 \(Игорь\): гоняет тесты и проверяет регрессии' "$prompt_file"
rg -q 'Работайте как "рой"' "$prompt_file"
rg -q '^   - CHILD_FILES_TOUCHED:' "$prompt_file"
rg -q '^   - CHILD_OVERLAP:' "$prompt_file"
rg -q '^   - CHILD_CHECKS:' "$prompt_file"

echo "OK"
