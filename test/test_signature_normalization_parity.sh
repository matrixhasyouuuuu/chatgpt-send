#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sample=$' \u00a0Line 1\r\nLine  2\t\twith   spaces \n'

shell_sig="$(
  CHATGPT_SEND_ROOT="$ROOT" RUN_ID="test-norm-parity" CHATGPT_URL="" \
  bash -lc '
    set -euo pipefail
    source "'"$ROOT"'/bin/lib/chatgpt_send/core.sh"
    text_signature "$1"
  ' _ "$sample"
)"

py_sig="$(
  python3 - <<'PY' "$sample"
import hashlib
import re
import sys

text = (sys.argv[1] or "")
text = text.replace("\u00a0", " ").replace("\r\n", "\n").replace("\r", "\n")
norm = re.sub(r"\s+", " ", text.strip())
if not norm:
    print("")
else:
    print(f"{hashlib.sha256(norm.encode('utf-8', errors='ignore')).hexdigest()[:12]}:{len(norm)}")
PY
)"

[[ "$shell_sig" == "$py_sig" ]]
echo "OK"
