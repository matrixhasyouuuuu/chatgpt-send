#!/usr/bin/env bash
set -euo pipefail

if [[ "${RUN_LIVE_CDP_E2E:-0}" != "1" ]]; then
  echo "SKIP_RUN_LIVE_CDP_E2E"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGR="$ROOT_DIR/scripts/chat_pool_manager.sh"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"
CHAT_POOL_FILE="$ROOT_DIR/state/chat_pool_e2e_2.txt"

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
pool_2="$tmp/chat_pool_2.txt"
printf '%s\n' "${chats[0]}" "${chats[1]}" >"$pool_2"

check_out="$("$MGR" check --file "$pool_2" --size 2)"
echo "$check_out" | rg -q -- '^POOL_CHECK_OK=1$'

set +e
probe_out="$("$MGR" probe --file "$pool_2" --transport cdp --chatgpt-send-path "$CHATGPT_SEND_BIN" --no-send 2>&1)"
probe_rc=$?
set -e
if echo "$probe_out" | rg -q -- '^SKIP_'; then
  echo "$probe_out"
  exit 0
fi
if [[ "$probe_rc" != "0" ]]; then
  if echo "$probe_out" | rg -q -- 'E_LOGIN_REQUIRED|E_CLOUDFLARE|E_UI_NOT_READY'; then
    echo "SKIP_LOGIN_REQUIRED"
    exit 0
  fi
  echo "$probe_out" >&2
  exit "$probe_rc"
fi

echo "$probe_out" | rg -q -- '^POOL_PROBE_OK=1$'
echo "$probe_out" | rg -q -- '^POOL_PROBE_TOTAL=2$'
report_jsonl="$(echo "$probe_out" | sed -n 's/^POOL_PROBE_REPORT_JSONL=//p' | tail -n 1)"
test -s "$report_jsonl"

python3 - "$report_jsonl" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
if len(rows) != 2:
    raise SystemExit(f"expected 2 probe rows, got {len(rows)}")
for row in rows:
    if row.get("status") != "OK":
        raise SystemExit(f"probe status not OK: {row}")
PY

echo "OK"
