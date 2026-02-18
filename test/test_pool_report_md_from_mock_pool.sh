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
  printf '%s\n' 'CHILD_RESULT: pool report mock test done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: pool report mock test done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Pool report task A
Pool report task B
Pool report task C
Pool report task D
Pool report task E
EOF

out="$(
  POOL_MODE=mock \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 0 \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
echo "$out" | rg -q -- '^POOL_REPORT_STATUS=ok$'

report_md="$(echo "$out" | sed -n 's/^POOL_REPORT_MD=//p' | tail -n 1)"
report_json="$(echo "$out" | sed -n 's/^POOL_REPORT_JSON=//p' | tail -n 1)"
final_jsonl="$(echo "$out" | sed -n 's/^POOL_FINAL_SUMMARY_JSONL=//p' | tail -n 1)"

test -s "$report_md"
test -s "$report_json"
test -s "$final_jsonl"

rg -q -- 'POOL_FLEET_GATE_STATUS' "$report_md"
rg -q -- 'chat_ok' "$report_md"

python3 - "$final_jsonl" "$report_md" <<'PY'
import json
import pathlib
import sys

final_rows = [json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if x.strip()]
md = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
if len(final_rows) != 5:
    raise SystemExit(f"expected 5 final rows, got {len(final_rows)}")
missing = []
for row in final_rows:
    rid = str(row.get("child_run_id", ""))
    if rid and rid not in md:
        missing.append(rid)
if missing:
    raise SystemExit(f"run_id missing in report: {missing}")
PY

echo "OK"
