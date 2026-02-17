#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chatgpt_send"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/root"
mkdir -p "$root/state"

# Create stale pid artifacts.
printf '%s\n' "not-a-pid" >"$root/state/chrome_9222.pid"
printf '%s\n' "999999" >"$root/state/chrome_9333.pid"

out1="$(CHATGPT_SEND_ROOT="$root" CHATGPT_SEND_CDP_PORT=9222 "$SCRIPT" --cleanup 2>&1)"
echo "$out1" | rg -q -- 'CLEANUP_KILLED_TOTAL='
echo "$out1" | rg -q -- 'CLEANUP_DONE'

# Idempotent second run.
out2="$(CHATGPT_SEND_ROOT="$root" CHATGPT_SEND_CDP_PORT=9222 "$SCRIPT" --cleanup 2>&1)"
echo "$out2" | rg -q -- 'CLEANUP_KILLED_TOTAL='
echo "$out2" | rg -q -- 'CLEANUP_DONE'

# Stale pid files should be gone.
if find "$root/state" -type f -name 'chrome_*.pid' | rg -q .; then
  echo "stale pid files were not fully cleaned" >&2
  exit 1
fi

echo "OK"
