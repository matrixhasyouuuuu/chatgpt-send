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
  printf '%s\n' 'CHILD_RESULT: agent pool mock done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: agent pool mock done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
Collect diagnostics for module A
Collect diagnostics for module B
Collect diagnostics for module C
Collect diagnostics for module D
Collect diagnostics for module E
EOF

chat_pool_file="$tmp/chat_pool.txt"
cat >"$chat_pool_file" <<'EOF'
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312981
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312982
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312983
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312984
https://chatgpt.com/c/6994c413-7cb4-8388-81a3-1d6ee4312985
EOF

pool_dir="$tmp/pool_run"
out="$(
  POOL_MODE=mock \
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --chat-pool-file "$chat_pool_file" \
    --mode mock \
    --concurrency 3 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$pool_dir" \
    --browser-policy optional \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
summary_jsonl="$(echo "$out" | sed -n 's/^POOL_SUMMARY_JSONL=//p' | tail -n 1)"
summary_csv="$(echo "$out" | sed -n 's/^POOL_SUMMARY_CSV=//p' | tail -n 1)"
final_summary_jsonl="$(echo "$out" | sed -n 's/^POOL_FINAL_SUMMARY_JSONL=//p' | tail -n 1)"
test -s "$summary_jsonl"
test -s "$summary_csv"
test -s "$final_summary_jsonl"
[[ "$(wc -l <"$summary_jsonl" | tr -d '[:space:]')" == "5" ]]
[[ "$(wc -l <"$final_summary_jsonl" | tr -d '[:space:]')" == "5" ]]

python3 - "$summary_jsonl" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in summary_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if len(rows) != 5:
    raise SystemExit(f"expected 5 summary rows, got {len(rows)}")

chat_urls = [row.get("chat_url", "") for row in rows]
if len(set(chat_urls)) != 5:
    raise SystemExit("chat_url must be unique per agent")

for row in rows:
    if row.get("spawn_rc") != 0:
        raise SystemExit(f"spawn_rc != 0 for agent {row.get('agent')}: {row.get('spawn_rc')}")
    if row.get("fail_kind") != "OK":
        raise SystemExit(f"fail_kind must be OK for mock run: {row.get('fail_kind')}")
    if row.get("chat_match") not in ("1", 1, True):
        raise SystemExit(f"chat_match expected 1/true, got: {row.get('chat_match')}")
    result_json = pathlib.Path(row.get("result_json", ""))
    if not result_json.exists():
        raise SystemExit(f"missing result_json for agent {row.get('agent')}: {result_json}")
    result_obj = json.loads(result_json.read_text(encoding="utf-8"))
    if result_obj.get("status") != "OK":
        raise SystemExit(f"unexpected status for agent {row.get('agent')}: {result_obj.get('status')}")
    transport_log = result_json.parent / "chatgpt_send" / "transport.log"
    if not transport_log.exists():
        raise SystemExit(f"missing transport.log for agent {row.get('agent')}: {transport_log}")
    t = transport_log.read_text(encoding="utf-8", errors="replace")
    if "[P1] transport=mock" not in t:
        raise SystemExit(f"transport log missing mock marker for agent {row.get('agent')}")
    if "E_ROUTE_MISMATCH" in t:
        raise SystemExit(f"route mismatch found in mock transport for agent {row.get('agent')}")
PY

python3 - "$final_summary_jsonl" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
if len(rows) != 5:
    raise SystemExit(f"expected 5 final rows, got {len(rows)}")
for row in rows:
    if row.get("final_status") != "ok":
        raise SystemExit(f"final_status must be ok: {row}")
    if row.get("fail_kind") != "OK":
        raise SystemExit(f"final fail_kind must be OK: {row}")
PY

echo "OK"
