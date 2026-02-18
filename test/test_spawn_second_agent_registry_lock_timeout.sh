#!/usr/bin/env bash
set -euo pipefail

SPAWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/spawn_second_agent"

tmp="$(mktemp -d)"
lock_holder_pid=""
cleanup() {
  if [[ -n "${lock_holder_pid:-}" ]]; then
    kill "$lock_holder_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

proj="$tmp/project"
log_dir="$tmp/logs"
tool_root="$tmp/tool_root"
registry="$tmp/fleet_registry.jsonl"
registry_lock="${registry}.lock"
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
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: registry lock timeout test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: registry lock timeout test done'
EOF
chmod +x "$fake_codex"

fake_chatgpt_send="$tool_root/bin/chatgpt_send"
cat >"$fake_chatgpt_send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$fake_chatgpt_send"

(
  exec 9>>"$registry_lock"
  flock 9
  printf '%s\n' "locked" >"$tmp/lock.ready"
  sleep 8
) &
lock_holder_pid=$!

deadline=$(( $(date +%s) + 4 ))
while [[ ! -f "$tmp/lock.ready" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "failed to acquire registry lock in helper process" >&2
    exit 1
  fi
  sleep 0.1
done

out="$(CHATGPT_SEND_FLEET_REGISTRY_FILE="$registry" \
  CHATGPT_SEND_FLEET_REGISTRY_LOCK_TIMEOUT_SEC=1 \
  CHATGPT_SEND_FLEET_AGENT_ID="3" \
  CHATGPT_SEND_FLEET_ATTEMPT="1" \
  CHATGPT_SEND_FLEET_ASSIGNED_CHAT_URL="https://chatgpt.com/c/lock-timeout-test" \
  "$SPAWN" \
    --project-path "$proj" \
    --task "Registry lock timeout check" \
    --iterations 1 \
    --launcher direct \
    --wait \
    --timeout-sec 40 \
    --log-dir "$log_dir" \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$fake_chatgpt_send" \
    --browser-disabled \
    --no-open-browser \
    --no-init-specialist-chat 2>&1)"

rg -q -- 'W_FLEET_REGISTRY_LOCK_TIMEOUT file=' <<<"$out"
run_id="$(echo "$out" | sed -n 's/^RUN_ID=//p' | head -n 1)"
[[ -n "$run_id" ]]

if [[ -f "$registry" ]]; then
  [[ "$(wc -l <"$registry" | tr -d '[:space:]')" == "0" ]]
fi

echo "OK"
