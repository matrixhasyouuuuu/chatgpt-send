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
  printf '%s\n' 'CHILD_RESULT: live cdp parallel done' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: live cdp parallel done'
exit 0
EOF
chmod +x "$fake_codex"

nonce="$(date +%s)"
out1_file="$tmp/out1.txt"
out2_file="$tmp/out2.txt"
init_specialist_flag=(--no-init-specialist-chat)
if [[ "${LIVE_INIT_SPECIALIST_CHAT:-0}" == "1" ]]; then
  init_specialist_flag=(--init-specialist-chat)
fi

launch_child() {
  local label="$1"
  local out_file="$2"
  CHATGPT_SEND_TRANSPORT=cdp \
  CHATGPT_SEND_FORCE_CHAT_URL="$live_chat_url" \
  CHATGPT_SEND_MAX_CDP_SLOTS=1 \
  CHATGPT_SEND_SLOT_WAIT_TIMEOUT_SEC=240 \
  CHATGPT_SEND_LOCK_TIMEOUT_SEC=240 \
  "$SPAWN" \
    --project-path "$proj" \
    --task "LIVE_CDP_PAR_${label}_${nonce}: Reply with exactly OK_CDP_PAR_${label}_${nonce}" \
    --iterations 1 \
    --launcher direct \
    --wait \
    --timeout-sec 420 \
    --log-dir "$log_dir" \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$CHATGPT_SEND_BIN" \
    --browser-required \
    "${init_specialist_flag[@]}" \
    --open-browser >"$out_file" 2>&1
}

launch_child A "$out1_file" &
pid1=$!
launch_child B "$out2_file" &
pid2=$!

set +e
wait "$pid1"
st1=$?
wait "$pid2"
st2=$?
set -e
if [[ "$st1" != "0" || "$st2" != "0" ]]; then
  echo "live parallel child launch failed: st1=$st1 st2=$st2" >&2
  sed -n '1,200p' "$out1_file" >&2 || true
  sed -n '1,200p' "$out2_file" >&2 || true
  exit 1
fi

out1="$(cat "$out1_file")"
out2="$(cat "$out2_file")"
echo "$out1" | rg -q -- '^CHILD_STATUS=0$'
echo "$out2" | rg -q -- '^CHILD_STATUS=0$'

res1="$(echo "$out1" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
res2="$(echo "$out2" | sed -n 's/^CHILD_RESULT_JSON=//p' | head -n 1)"
log1="$(echo "$out1" | sed -n 's/^LOG_FILE=//p' | head -n 1)"
log2="$(echo "$out2" | sed -n 's/^LOG_FILE=//p' | head -n 1)"
chat_log_dir1="$(echo "$out1" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
chat_log_dir2="$(echo "$out2" | sed -n 's/^CHILD_CHATGPT_SEND_LOG_DIR=//p' | head -n 1)"
transport1="$chat_log_dir1/transport.log"
transport2="$chat_log_dir2/transport.log"

test -s "$res1"
test -s "$res2"
[[ -f "$log1" ]]
[[ -f "$log2" ]]
test -s "$transport1"
test -s "$transport2"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$res1"
rg -q -- '"status"[[:space:]]*:[[:space:]]*"OK"' "$res2"
rg -q -- '"browser_used"[[:space:]]*:[[:space:]]*true' "$res1"
rg -q -- '"browser_used"[[:space:]]*:[[:space:]]*true' "$res2"

if rg -n -- 'E_SLOT_ACQUIRE_TIMEOUT' "$log1" "$log2" >/dev/null; then
  echo "unexpected E_SLOT_ACQUIRE_TIMEOUT in live parallel test" >&2
  exit 1
fi
rg -q -- 'SLOT_ACQUIRE' "$log1"
rg -q -- 'SLOT_RELEASE' "$log1"
rg -q -- 'SLOT_ACQUIRE' "$log2"
rg -q -- 'SLOT_RELEASE' "$log2"

if rg -n -- 'E_LOGIN_REQUIRED|E_CLOUDFLARE' "$transport1" "$transport2" >/dev/null; then
  echo "SKIP_LOGIN_REQUIRED"
  sed -n '1,120p' "$transport1" || true
  sed -n '1,120p' "$transport2" || true
  exit 0
fi
if rg -n -- 'E_ROUTE_MISMATCH|E_FETCH_LAST_FAILED|E_UI_NOT_READY' "$transport1" "$transport2" >/dev/null; then
  echo "unexpected live CDP error markers in parallel transport logs" >&2
  sed -n '1,120p' "$transport1" >&2 || true
  sed -n '1,120p' "$transport2" >&2 || true
  exit 1
fi

if [[ -n "${LIVE_ARTIFACT_DIR:-}" ]]; then
  mkdir -p "$LIVE_ARTIFACT_DIR"
  cp "$res1" "$LIVE_ARTIFACT_DIR/child_result_a.json"
  cp "$res2" "$LIVE_ARTIFACT_DIR/child_result_b.json"
  cp "$log1" "$LIVE_ARTIFACT_DIR/child_a.log"
  cp "$log2" "$LIVE_ARTIFACT_DIR/child_b.log"
  cp "$transport1" "$LIVE_ARTIFACT_DIR/transport_a.log"
  cp "$transport2" "$LIVE_ARTIFACT_DIR/transport_b.log"
  res1="$LIVE_ARTIFACT_DIR/child_result_a.json"
  res2="$LIVE_ARTIFACT_DIR/child_result_b.json"
  log1="$LIVE_ARTIFACT_DIR/child_a.log"
  log2="$LIVE_ARTIFACT_DIR/child_b.log"
  transport1="$LIVE_ARTIFACT_DIR/transport_a.log"
  transport2="$LIVE_ARTIFACT_DIR/transport_b.log"
fi

echo "CHILD_RESULT_JSON_A=$res1"
echo "CHILD_RESULT_JSON_B=$res2"
echo "CHILD_LOG_FILE_A=$log1"
echo "CHILD_LOG_FILE_B=$log2"
echo "TRANSPORT_LOG_A=$transport1"
echo "TRANSPORT_LOG_B=$transport2"
sed -n '1,60p' "$transport1"
echo "OK"
