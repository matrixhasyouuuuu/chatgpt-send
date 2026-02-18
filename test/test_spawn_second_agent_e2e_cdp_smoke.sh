#!/usr/bin/env bash
set -euo pipefail

if [[ "${RUN_LIVE_CDP_E2E:-0}" != "1" ]]; then
  echo "SKIP_RUN_LIVE_CDP_E2E"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT_DIR/bin/spawn_second_agent"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

if ! curl -fsS "http://127.0.0.1:9222/json/version" >/dev/null 2>&1; then
  echo "SKIP_CDP_DOWN"
  exit 0
fi

live_chat_url="${LIVE_CHAT_URL:-}"
if [[ ! "$live_chat_url" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
  live_chat_url=""
fi
if [[ -z "$live_chat_url" ]]; then
  for path in "$ROOT_DIR/state/chatgpt_url_e2e.txt" "$ROOT_DIR/state/work_chat_url.txt" "$ROOT_DIR/state/chatgpt_url.txt"; do
    if [[ -f "$path" ]]; then
      candidate="$(sed -n '1p' "$path" | tr -d '\r' | xargs || true)"
      if [[ "$candidate" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
        live_chat_url="$candidate"
        break
      fi
    fi
  done
fi
if [[ -z "$live_chat_url" ]]; then
  echo "SKIP_NO_WORK_CHAT_URL"
  exit 0
fi

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
  printf '%s\n' 'CHILD_RESULT: live cdp smoke done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: live cdp smoke done'
exit 0
EOF
chmod +x "$fake_codex"

nonce="$(date +%s)"
init_specialist_flag=(--no-init-specialist-chat)
if [[ "${LIVE_INIT_SPECIALIST_CHAT:-0}" == "1" ]]; then
  init_specialist_flag=(--init-specialist-chat)
fi
out="$(
  CHATGPT_SEND_TRANSPORT=cdp \
  CHATGPT_SEND_FORCE_CHAT_URL="$live_chat_url" \
  "$SPAWN" \
    --project-path "$proj" \
    --task "LIVE_CDP_SMOKE_${nonce}: Reply with exactly OK_CDP_SMOKE_${nonce}" \
    --iterations 1 \
    --launcher direct \
    --wait \
    --timeout-sec 240 \
    --log-dir "$log_dir" \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" \
    --browser-required \
    "${init_specialist_flag[@]}" \
    --open-browser 2>&1
)"

echo "$out" | rg -q -- '^BROWSER_POLICY=required$'
echo "$out" | rg -q -- '^CHILD_STATUS=0$'

child_result_json="$(echo "$out" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
child_log_file="$(echo "$out" | sed -n 's/^LOG_FILE=//p' | head -n 1)"
chatgpt_log_dir="$(echo "$out" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
transport_log="$chatgpt_log_dir/transport.log"

test -s "$child_result_json"
[[ -f "$child_log_file" ]]
test -s "$transport_log"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$child_result_json"
rg -q -- '"browser_used"[[:space:]]*:[[:space:]]*true' "$child_result_json"
rg -q -- 'CHILD_BROWSER_USED:[[:space:]]*yes' "$child_log_file"

if rg -n -- 'E_LOGIN_REQUIRED|E_CLOUDFLARE' "$transport_log" >/dev/null; then
  echo "SKIP_LOGIN_REQUIRED"
  sed -n '1,120p' "$transport_log" || true
  exit 0
fi
if rg -n -- 'E_ROUTE_MISMATCH|E_FETCH_LAST_FAILED|E_UI_NOT_READY' "$transport_log" >/dev/null; then
  echo "unexpected live CDP error markers in transport log" >&2
  sed -n '1,120p' "$transport_log" >&2 || true
  exit 1
fi

if [[ -n "${LIVE_ARTIFACT_DIR:-}" ]]; then
  mkdir -p "$LIVE_ARTIFACT_DIR"
  cp "$child_result_json" "$LIVE_ARTIFACT_DIR/child_result.json"
  cp "$child_log_file" "$LIVE_ARTIFACT_DIR/child.log"
  cp "$transport_log" "$LIVE_ARTIFACT_DIR/transport.log"
  child_result_json="$LIVE_ARTIFACT_DIR/child_result.json"
  child_log_file="$LIVE_ARTIFACT_DIR/child.log"
  transport_log="$LIVE_ARTIFACT_DIR/transport.log"
fi

echo "CHILD_RESULT_JSON=$child_result_json"
echo "CHILD_LOG_FILE=$child_log_file"
echo "TRANSPORT_LOG=$transport_log"
sed -n '1,60p' "$transport_log"
echo "OK"
