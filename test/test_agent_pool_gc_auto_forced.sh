#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
mkdir -p "$proj"

runs_root="$tmp/runs"
mkdir -p "$runs_root"
for n in a b c; do
  d="$runs_root/old_$n"
  mkdir -p "$d"
  printf '{}\n' >"$d/fleet.summary.json"
  printf '%s\n' "old-$n" >"$d/fleet_registry.jsonl"
done
touch -d '7 days ago' "$runs_root/old_a"
touch -d '6 days ago' "$runs_root/old_b"
touch -d '5 days ago' "$runs_root/old_c"

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
  printf '%s\n' 'CHILD_RESULT: gc auto test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: gc auto test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
GC auto task A
EOF

out="$(
  POOL_MODE=mock \
  POOL_RUNS_ROOT="$runs_root" \
  POOL_GC=auto \
  POOL_GC_FREE_WARN_PCT=100 \
  POOL_GC_KEEP_LAST=1 \
  POOL_GC_KEEP_HOURS=0 \
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

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
echo "$out" | rg -q -- '^POOL_GC_APPLIED=1$'
echo "$out" | rg -q -- '^POOL_GC_REASON=auto_low_disk$'

gc_log="$(echo "$out" | sed -n 's/^POOL_GC_LOG=//p' | tail -n 1)"
test -s "$gc_log"
rg -q -- '^GC_START ' "$gc_log"
rg -q -- 'GC_DELETE dir=' "$gc_log"

test ! -d "$runs_root/old_a"
test ! -d "$runs_root/old_b"
test ! -d "$runs_root/old_c"

echo "OK"
