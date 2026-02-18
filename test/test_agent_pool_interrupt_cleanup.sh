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
sleep 20
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: interrupt cleanup test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: interrupt cleanup test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Interrupt task A
Interrupt task B
Interrupt task C
Interrupt task D
EOF

lock_file="$tmp/pool.lock"
pool_dir="$tmp/pool_run"
out_file="$tmp/pool.out"
(
  POOL_MODE=mock \
  POOL_LOCK_FILE="$lock_file" \
  POOL_KILL_GRACE_SEC=1 \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" >"$out_file" 2>&1
) &
pool_pid=$!

deadline=$(( $(date +%s) + 20 ))
while true; do
  if [[ -s "$pool_dir/fleet_registry.jsonl" ]]; then
    break
  fi
  if ! kill -0 "$pool_pid" >/dev/null 2>&1; then
    echo "pool exited before registry got entries" >&2
    cat "$out_file" >&2 || true
    exit 1
  fi
  if (( $(date +%s) >= deadline )); then
    echo "timeout waiting for registry rows" >&2
    exit 1
  fi
  sleep 0.2
done

kill -INT "$pool_pid" >/dev/null 2>&1 || true
set +e
wait "$pool_pid"
pool_rc=$?
set -e
pool_pid=""

[[ "$pool_rc" == "130" ]]
rg -q -- '^POOL_STATUS=INTERRUPTED$' "$out_file"
rg -q -- '^POOL_ABORT=1$' "$out_file"
rg -q -- '^POOL_ABORT_SIGNAL=INT$' "$out_file"

python3 - "$pool_dir/fleet_registry.jsonl" <<'PY'
import json
import pathlib
import signal
import sys

registry = pathlib.Path(sys.argv[1])
if not registry.exists():
    raise SystemExit("registry missing")

alive = []
for raw in registry.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    pid_file = pathlib.Path(str(obj.get("pid_file", "")))
    if not pid_file.exists():
        continue
    pid_s = pid_file.read_text(encoding="utf-8", errors="replace").strip()
    if not pid_s.isdigit():
        continue
    pid = int(pid_s)
    try:
        signal.raise_signal  # pyflakes quiet
        import os
        os.kill(pid, 0)
    except OSError:
        continue
    alive.append(pid)

if alive:
    raise SystemExit(f"child pids still alive after interrupt cleanup: {alive}")
PY

echo "OK"
