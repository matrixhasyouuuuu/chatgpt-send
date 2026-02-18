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
    -o|--output-last-message) out="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null || true
sleep 2
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: auto monitor test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: auto monitor test done'
EOF
chmod +x "$fake_codex"

out="$("$SPAWN" \
  --project-path "$proj" \
  --task "Auto monitor smoke" \
  --iterations 1 \
  --launcher direct \
  --browser-disabled \
  --no-open-browser \
  --no-init-specialist-chat \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" 2>&1)"

echo "$out" | rg -q -- '^AUTO_MONITOR=1$'
exit_file="$(echo "$out" | sed -n 's/^EXIT_FILE=//p' | head -n 1)"
last_file="$(echo "$out" | sed -n 's/^LAST_FILE=//p' | head -n 1)"
monitor_log="$(echo "$out" | sed -n 's/^MONITOR_LOG_FILE=//p' | head -n 1)"
monitor_pid_file="$(echo "$out" | sed -n 's/^MONITOR_PID_FILE=//p' | head -n 1)"

[[ -f "$monitor_pid_file" ]]

deadline=$(( $(date +%s) + 25 ))
while [[ ! -f "$exit_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "timeout waiting for exit file: $exit_file" >&2
    exit 1
  fi
  sleep 1
done

deadline=$(( $(date +%s) + 10 ))
while true; do
  if [[ -f "$monitor_log" ]] && rg -q -- 'event=done' "$monitor_log"; then
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "monitor did not write done event: $monitor_log" >&2
    [[ -f "$monitor_log" ]] && sed -n '1,120p' "$monitor_log" >&2 || true
    exit 1
  fi
  sleep 1
done

monitor_pid="$(cat "$monitor_pid_file" | tr -d '[:space:]')"
deadline=$(( $(date +%s) + 10 ))
while kill -0 "$monitor_pid" 2>/dev/null; do
  if (( $(date +%s) >= deadline )); then
    echo "monitor pid still alive: $monitor_pid" >&2
    exit 1
  fi
  sleep 1
done

rg -q -- 'event=start' "$monitor_log"
rg -q -- 'event=done' "$monitor_log"
rg -q -- '^CHILD_RESULT: auto monitor test done$' "$last_file"

echo "OK"
