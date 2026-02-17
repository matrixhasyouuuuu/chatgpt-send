#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
RUN_ID="${CHATGPT_SEND_PROFILE_WRAP_RUN_ID:-profile-$(date +%s)-$RANDOM}"
PROTECT_URL="${CHATGPT_SEND_PROTECT_CHAT_URL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP=1
      shift
      ;;
    --run-id)
      RUN_ID="${2:-$RUN_ID}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--keep] [--run-id ID] -- <command ...>" >&2
  exit 2
fi

if [[ -z "${PROTECT_URL//[[:space:]]/}" ]] && [[ -f "$ROOT/state/chatgpt_url.txt" ]]; then
  PROTECT_URL="$(head -n 1 "$ROOT/state/chatgpt_url.txt" || true)"
fi

PROFILE_BASE="$ROOT/state/profiles/test-${RUN_ID}"
RUNTIME_ROOT="$PROFILE_BASE/runtime_root"
mkdir -p "$RUNTIME_ROOT/state"
mkdir -p "$PROFILE_BASE/manual-login-profile"
ln -sfn "$ROOT/bin" "$RUNTIME_ROOT/bin"
ln -sfn "$ROOT/docs" "$RUNTIME_ROOT/docs"

export CHATGPT_SEND_ROOT="$RUNTIME_ROOT"
export CHATGPT_SEND_PROFILE_DIR="$PROFILE_BASE/manual-login-profile"
if [[ -n "${PROTECT_URL//[[:space:]]/}" ]]; then
  export CHATGPT_SEND_PROTECT_CHAT_URL="$PROTECT_URL"
fi

echo "PROFILE_WRAP run_id=${RUN_ID} root=${CHATGPT_SEND_ROOT} profile_dir=${CHATGPT_SEND_PROFILE_DIR} protect_url=${PROTECT_URL:-none}" >&2

set +e
(cd "$ROOT" && "$@")
st=$?
set -e

if [[ "$KEEP" -ne 1 ]]; then
  rm -rf "$PROFILE_BASE"
else
  echo "PROFILE_WRAP keep=1 path=${PROFILE_BASE}" >&2
fi

exit "$st"
