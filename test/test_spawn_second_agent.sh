#!/usr/bin/env bash
set -euo pipefail

SPAWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/spawn_second_agent"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
log_dir="$tmp/logs"
tool_root="$tmp/tool_root"
mkdir -p "$proj" "$log_dir" "$tool_root/bin" "$tool_root/docs"

# Fake codex binary for deterministic test.
fake_codex="$tmp/fake_codex"
codex_args_file="$tmp/fake_codex_args.txt"
cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
args_file="${FAKE_CODEX_ARGS_FILE:-}"
if [[ -n "$args_file" ]]; then
  printf '%s\n' "$*" >"$args_file"
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-last-message) out="${2:-}"; shift 2;;
    *) shift;;
  esac
done
# consume stdin prompt (not used)
cat >/dev/null || true
if [[ -n "${out:-}" ]]; then
  printf '%s\n' 'CHILD_RESULT: fake solved task' >"$out"
fi
printf '%s\n' 'CHILD_RESULT: fake solved task'
EOF
chmod +x "$fake_codex"

# Fake chatgpt_send to capture child env.
fake_chatgpt_send="$tool_root/bin/chatgpt_send"
env_capture="$tmp/chatgpt_env.txt"
cat >"$fake_chatgpt_send" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${FAKE_CHATGPT_FAIL_INIT:-0}" == "1" ]] && [[ "\$*" == *"--init-specialist"* ]]; then
  exit 5
fi
printf 'ROOT=%s\nPORT=%s\nPROFILE=%s\nPRESERVE_TABS=%s\nLOCK_FILE=%s\nLOCK_TIMEOUT=%s\nAUTO_TIMEOUT=%s\nARGS=%s\n' \
  "\${CHATGPT_SEND_ROOT:-}" \
  "\${CHATGPT_SEND_CDP_PORT:-}" \
  "\${CHATGPT_SEND_PROFILE_DIR:-}" \
  "\${CHATGPT_SEND_PRESERVE_TABS:-}" \
  "\${CHATGPT_SEND_LOCK_FILE:-}" \
  "\${CHATGPT_SEND_LOCK_TIMEOUT_SEC:-}" \
  "\${CHATGPT_SEND_AUTO_TIMEOUT_SEC:-}" \
  "\$*" >>"$env_capture"
EOF
chmod +x "$fake_chatgpt_send"

out="$(FAKE_CODEX_ARGS_FILE="$codex_args_file" "$SPAWN" \
  --project-path "$proj" \
  --task "Investigate and solve test issue" \
  --iterations 2 \
  --launcher direct \
  --wait \
  --timeout-sec 30 \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" \
  --chatgpt-send-path "$fake_chatgpt_send" 2>&1)"

echo "$out" | rg -q -- '^RUN_ID='
echo "$out" | rg -q -- '^STATE_ROOT='
echo "$out" | rg -q -- '^CDP_PORT='
echo "$out" | rg -q -- '^BROWSER_POLICY=optional$'
echo "$out" | rg -q -- '^INIT_SPECIALIST_CHAT=1$'
echo "$out" | rg -q -- '^CHILD_STATUS=0$'
echo "$out" | rg -q -- '^CHILD_RESULT=CHILD_RESULT: fake solved task$'

state_root="$(echo "$out" | sed -n 's/^STATE_ROOT=//p' | head -n 1)"
cdp_port="$(echo "$out" | sed -n 's/^CDP_PORT=//p' | head -n 1)"
browser_mode="$(echo "$out" | sed -n 's/^BROWSER_MODE=//p' | head -n 1)"
last_file="$(echo "$out" | sed -n 's/^LAST_FILE=//p' | head -n 1)"

[[ -d "$state_root" ]]
[[ -f "$last_file" ]]
rg -q -- '^CHILD_RESULT: fake solved task$' "$last_file"
[[ "$browser_mode" == "shared" ]]
[[ "$state_root" == "$tool_root/state/child-agents-shared/"* ]]
[[ "$cdp_port" == "9222" ]]

# Verify default codex arg for non-trusted/non-git directories is passed.
rg -q -- '--skip-git-repo-check' "$codex_args_file"

# Verify browser helper received child env.
rg -q -- "ROOT=$state_root" "$env_capture"
rg -q -- "PORT=$cdp_port" "$env_capture"
rg -q -- "PROFILE=$tool_root/state/manual-login-profile" "$env_capture"
rg -q -- "PRESERVE_TABS=1" "$env_capture"
rg -q -- "LOCK_FILE=$tool_root/state/shared-browser.lock" "$env_capture"
rg -q -- "LOCK_TIMEOUT=180" "$env_capture"
rg -q -- "AUTO_TIMEOUT=120" "$env_capture"
rg -q -- "ARGS=--open-browser --chatgpt-url https://chatgpt.com/" "$env_capture"
rg -q -- 'ARGS=.*--init-specialist --topic child-' "$env_capture"

# Verify browser-disabled policy never opens browser.
: >"$env_capture"
out_disabled="$(FAKE_CODEX_ARGS_FILE="$codex_args_file" "$SPAWN" \
  --project-path "$proj" \
  --task "No browser task" \
  --iterations 1 \
  --launcher direct \
  --wait \
  --timeout-sec 30 \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" \
  --chatgpt-send-path "$fake_chatgpt_send" \
  --browser-disabled 2>&1)"
echo "$out_disabled" | rg -q -- '^BROWSER_POLICY=disabled$'
if rg -q -- 'ARGS=--open-browser --chatgpt-url https://chatgpt.com/' "$env_capture"; then
  echo "unexpected browser open in --browser-disabled mode" >&2
  exit 1
fi

# Verify browser-required policy fails without explicit CHILD_BROWSER_USED: yes evidence.
set +e
out_required="$(FAKE_CODEX_ARGS_FILE="$codex_args_file" "$SPAWN" \
  --project-path "$proj" \
  --task "Browser required task" \
  --iterations 1 \
  --launcher direct \
  --wait \
  --timeout-sec 30 \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" \
  --chatgpt-send-path "$fake_chatgpt_send" \
  --browser-required 2>&1)"
st_required=$?
set -e
[[ "$st_required" -ne 0 ]]
echo "$out_required" | rg -q -- '^BROWSER_POLICY=required$'
echo "$out_required" | rg -q -- '^CHILD_STATUS_NOTE=browser_policy_failed$'

# Verify early failure still writes exit metadata so coordinator won't hang.
set +e
out_fail_fast="$(FAKE_CHATGPT_FAIL_INIT=1 FAKE_CODEX_ARGS_FILE="$codex_args_file" "$SPAWN" \
  --project-path "$proj" \
  --task "Init should fail fast" \
  --iterations 1 \
  --launcher direct \
  --wait \
  --timeout-sec 30 \
  --log-dir "$log_dir" \
  --codex-bin "$fake_codex" \
  --chatgpt-send-path "$fake_chatgpt_send" \
  --browser-required 2>&1)"
st_fail_fast=$?
set -e
[[ "$st_fail_fast" -ne 0 ]]
echo "$out_fail_fast" | rg -q -- '^CHILD_STATUS='
exit_file_fail_fast="$(echo "$out_fail_fast" | sed -n 's/^EXIT_FILE=//p' | head -n 1)"
[[ -n "$exit_file_fail_fast" ]]
[[ -f "$exit_file_fail_fast" ]]

echo "OK"
