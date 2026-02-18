#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"
BOOTSTRAP_FILE="${BOOTSTRAP_FILE:-$ROOT_DIR/docs/specialist_bootstrap.txt}"
CACHE_FILE="${BOOTSTRAP_CACHE_FILE:-$ROOT_DIR/state/specialist_bootstrap_cache.tsv}"
TTL_SEC="${BOOTSTRAP_TTL_SEC:-86400}"
CHAT_URL="${LIVE_CHAT_URL:-}"

if [[ ! -x "$CHATGPT_SEND_BIN" ]]; then
  echo "BOOTSTRAP_ONCE fail reason=chatgpt_send_missing path=$CHATGPT_SEND_BIN" >&2
  exit 2
fi
if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
  echo "BOOTSTRAP_ONCE fail reason=bootstrap_file_missing path=$BOOTSTRAP_FILE" >&2
  exit 3
fi
if [[ -z "$CHAT_URL" ]] || [[ ! "$CHAT_URL" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]; then
  echo "BOOTSTRAP_ONCE fail reason=invalid_live_chat_url value=${CHAT_URL:-none}" >&2
  exit 4
fi
if [[ ! "$TTL_SEC" =~ ^[0-9]+$ ]]; then
  echo "BOOTSTRAP_ONCE fail reason=invalid_ttl value=$TTL_SEC" >&2
  exit 5
fi

now_ts="$(date +%s)"
bootstrap_sig="$(sha256sum "$BOOTSTRAP_FILE" | awk '{print $1}')"

cached_ts=""
if [[ -f "$CACHE_FILE" ]]; then
  cached_ts="$(
    awk -F $'\t' -v chat_url="$CHAT_URL" -v sig="$bootstrap_sig" \
      '$1==chat_url && $2==sig {print $3}' "$CACHE_FILE" | tail -n 1
  )"
fi

if [[ -n "${cached_ts:-}" ]] && [[ "$cached_ts" =~ ^[0-9]+$ ]]; then
  age_sec=$((now_ts - cached_ts))
  if (( age_sec >= 0 )) && (( age_sec < TTL_SEC )); then
    echo "BOOTSTRAP_ONCE skip reason=cached ttl_sec=$TTL_SEC age_sec=$age_sec chat_url=$CHAT_URL bootstrap_sig=$bootstrap_sig"
    exit 0
  fi
fi

echo "BOOTSTRAP_ONCE send chat_url=$CHAT_URL bootstrap_sig=$bootstrap_sig ttl_sec=$TTL_SEC"
tmp_out="$(mktemp)"
set +e
"$CHATGPT_SEND_BIN" --chatgpt-url "$CHAT_URL" --prompt-file "$BOOTSTRAP_FILE" >"$tmp_out" 2>&1
rc=$?
set -e
cat "$tmp_out"
rm -f "$tmp_out"
if [[ "$rc" != "0" ]]; then
  echo "BOOTSTRAP_ONCE fail reason=chatgpt_send_rc rc=$rc chat_url=$CHAT_URL bootstrap_sig=$bootstrap_sig" >&2
  exit "$rc"
fi

mkdir -p "$(dirname "$CACHE_FILE")"
touch "$CACHE_FILE"
tmp_cache="$(mktemp)"
awk -F $'\t' -v chat_url="$CHAT_URL" -v sig="$bootstrap_sig" \
  '!(NF >= 2 && $1==chat_url && $2==sig)' "$CACHE_FILE" >"$tmp_cache" || true
printf '%s\t%s\t%s\n' "$CHAT_URL" "$bootstrap_sig" "$now_ts" >>"$tmp_cache"
mv "$tmp_cache" "$CACHE_FILE"

echo "BOOTSTRAP_ONCE done chat_url=$CHAT_URL bootstrap_sig=$bootstrap_sig"

