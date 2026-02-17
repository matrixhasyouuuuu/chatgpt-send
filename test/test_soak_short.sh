#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOAK_RUNNER="$ROOT/scripts/soak_runner.sh"
GATE_CHECK="$ROOT/scripts/release_gate_check.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_send="$tmp/fake_chatgpt_send.sh"
cat >"$fake_send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "PROFILE_DIR path=/tmp/fake-profile"
echo "fake assistant reply"
exit 0
EOF
chmod +x "$fake_send"

run_id="soak-short-$(date +%s)-$$"
bash "$SOAK_RUNNER" --iters 20 --run-id "$run_id" --chatgpt-send-bin "$fake_send" \
  --force-chat-url "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

summary="$ROOT/state/runs/$run_id/soak/summary.txt"
[[ -f "$summary" ]]
rg -q -- 'RELEASE_GATE: PASS' "$summary"
rg -q -- '^soak_failed=0$' "$summary"

bash "$GATE_CHECK" --profile soak --run-id "$run_id" >/tmp/soak_check_${run_id}.log
rg -q -- 'RELEASE_GATE: PASS' /tmp/soak_check_${run_id}.log

echo "OK"
