#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out="$("$ROOT/scripts/prompt_lint.sh" 2>&1)"
echo "$out" | rg -q -- 'PROMPT_LINT_FAILS=0'
echo "$out" | rg -q -- 'PROMPT_LINT_OK=1'

echo "T_prompt_lint_v0: OK"
