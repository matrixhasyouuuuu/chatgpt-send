#!/usr/bin/env bash
set -euo pipefail

if [[ "${RUN_LIVE_CDP_E2E:-0}" != "1" ]]; then
  echo "SKIP_RUN_LIVE_CDP_E2E"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POOL_RUN="$ROOT_DIR/scripts/agent_pool_run.sh"
CHAT_POOL_FILE="$ROOT_DIR/state/chat_pool_e2e_2.txt"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

if ! curl -fsS "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
  echo "SKIP_CDP_DOWN"
  exit 0
fi

if [[ ! -f "$CHAT_POOL_FILE" ]]; then
  echo "SKIP_NO_E2E_CHAT_POOL"
  exit 0
fi

mapfile -t chats < <(sed -e 's/\r$//' "$CHAT_POOL_FILE" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')
if (( ${#chats[@]} < 2 )); then
  echo "SKIP_NO_E2E_CHAT_POOL"
  exit 0
fi
for u in "${chats[@]:0:2}"; do
  if [[ ! "$u" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
    echo "SKIP_NO_E2E_CHAT_POOL"
    exit 0
  fi
done

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
  printf '%s\n' 'CHILD_RESULT: agent pool live done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: agent pool live done'
EOF
chmod +x "$fake_codex"

tasks_file="$tmp/tasks.txt"
cat >"$tasks_file" <<'EOF'
LIVE pool diagnostics A
LIVE pool diagnostics B
EOF

chat_pool_2="$tmp/chat_pool_2.txt"
printf '%s\n' "${chats[0]}" "${chats[1]}" >"$chat_pool_2"

pool_dir="$tmp/pool_live_run"
out="$(
  "$POOL_RUN" \
    --project-path "$proj" \
    --tasks-file "$tasks_file" \
    --chat-pool-file "$chat_pool_2" \
    --mode live \
    --concurrency 2 \
    --iterations 1 \
    --retry-max 0 \
    --log-dir "$pool_dir" \
    --browser-policy required \
    --no-init-specialist-chat \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" 2>&1
)"

echo "$out" | rg -q -- '^POOL_STATUS=OK$'
summary_jsonl="$(echo "$out" | sed -n 's/^POOL_SUMMARY_JSONL=//p' | tail -n 1)"
final_summary_jsonl="$(echo "$out" | sed -n 's/^POOL_FINAL_SUMMARY_JSONL=//p' | tail -n 1)"
test -s "$summary_jsonl"
test -s "$final_summary_jsonl"
[[ "$(wc -l <"$summary_jsonl" | tr -d '[:space:]')" == "2" ]]
[[ "$(wc -l <"$final_summary_jsonl" | tr -d '[:space:]')" == "2" ]]

python3 - "$summary_jsonl" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in summary_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if len(rows) != 2:
    raise SystemExit(f"expected 2 rows, got {len(rows)}")
for row in rows:
    if row.get("spawn_rc") != 0:
        raise SystemExit(f"spawn_rc != 0: {row}")
    if row.get("fail_kind") != "OK":
        raise SystemExit(f"unexpected fail_kind for live row: {row.get('fail_kind')}")
    if row.get("chat_match") not in ("1", 1, True):
        raise SystemExit(f"chat_match expected 1/true, got: {row.get('chat_match')}")
    result_json = pathlib.Path(row.get("result_json", ""))
    result = json.loads(result_json.read_text(encoding="utf-8"))
    if result.get("status") != "OK":
        raise SystemExit(f"status != OK: {result.get('status')}")
    if result.get("browser_used") is not True:
        raise SystemExit(f"browser_used != true: {result.get('browser_used')}")
    transport = result_json.parent / "chatgpt_send" / "transport.log"
    t = transport.read_text(encoding="utf-8", errors="replace")
    for marker in ("E_ROUTE_MISMATCH", "E_FETCH_LAST_FAILED", "E_LOGIN_REQUIRED", "E_CLOUDFLARE"):
        if marker in t:
            raise SystemExit(f"unexpected marker {marker} in {transport}")
PY

python3 - "$final_summary_jsonl" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
if len(rows) != 2:
    raise SystemExit(f"expected 2 final rows, got {len(rows)}")
for row in rows:
    if row.get("final_status") != "ok":
        raise SystemExit(f"final_status must be ok: {row}")
    if row.get("fail_kind") != "OK":
        raise SystemExit(f"final fail_kind must be OK: {row}")
PY

echo "OK"
