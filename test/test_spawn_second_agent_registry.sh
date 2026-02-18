#!/usr/bin/env bash
set -euo pipefail

SPAWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/spawn_second_agent"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
log_dir="$tmp/logs"
tool_root="$tmp/tool_root"
registry="$tmp/fleet_registry.jsonl"
mkdir -p "$proj" "$log_dir" "$tool_root/bin" "$tool_root/docs"

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
if [[ -n "$out" ]]; then
  printf '%s\n' 'CHILD_RESULT: registry test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: registry test done'
EOF
chmod +x "$fake_codex"

fake_chatgpt_send="$tool_root/bin/chatgpt_send"
cat >"$fake_chatgpt_send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$fake_chatgpt_send"

out="$(CHATGPT_SEND_FLEET_REGISTRY_FILE="$registry" \
  CHATGPT_SEND_FLEET_AGENT_ID="7" \
  CHATGPT_SEND_FLEET_ATTEMPT="2" \
  CHATGPT_SEND_FLEET_ASSIGNED_CHAT_URL="https://chatgpt.com/c/test-assigned-chat" \
  "$SPAWN" \
    --project-path "$proj" \
    --task "Registry append check" \
    --iterations 1 \
    --launcher direct \
    --wait \
    --timeout-sec 30 \
    --log-dir "$log_dir" \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$fake_chatgpt_send" \
    --browser-disabled \
    --no-open-browser \
    --no-init-specialist-chat 2>&1)"

run_id="$(echo "$out" | sed -n 's/^RUN_ID=//p' | head -n 1)"
run_dir="$(echo "$out" | sed -n 's/^CHILD_RUN_DIR=//p' | head -n 1)"
[[ -n "$run_id" ]]
[[ -n "$run_dir" ]]
test -s "$registry"

python3 - "$registry" "$run_id" "$run_dir" <<'PY'
import json
import sys

registry, run_id, run_dir = sys.argv[1:4]
rows = []
with open(registry, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))

assert rows, "registry is empty"
row = rows[-1]
assert row["run_id"] == run_id, row
assert row["run_dir"] == run_dir, row
assert row["agent_id"] == "7", row
assert row["attempt"] == 2, row
assert row["assigned_chat_url"] == "https://chatgpt.com/c/test-assigned-chat", row
PY

echo "OK"
