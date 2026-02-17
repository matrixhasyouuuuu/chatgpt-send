#!/usr/bin/env bash
set -euo pipefail

SPAWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/spawn_second_agent"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

proj="$tmp/project"
log_dir="$tmp/logs"
tool_root="$tmp/tool_root"
mkdir -p "$proj" "$log_dir" "$tool_root/bin" "$tool_root/docs"

# Fake codex: always returns CHILD_RESULT.
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
  printf '%s\n' 'CHILD_BROWSER_USED: yes ; REASON: slot-test ; EVIDENCE: https://chatgpt.com/c/abcd-1234' >"$out"
  printf '%s\n' 'CHILD_RESULT: slot-test done' >>"$out"
fi
printf '%s\n' 'CHILD_RESULT: slot-test done'
exit 0
EOF
chmod +x "$fake_codex"

# Fake chatgpt_send: sleeps a bit to force overlap, and can return chat URL.
fake_chatgpt_send="$tool_root/bin/chatgpt_send"
cat >"$fake_chatgpt_send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep "${FAKE_CHATGPT_SEND_SLEEP:-0.2}"
if [[ "$*" == *"--show-chatgpt-url"* ]]; then
  echo "https://chatgpt.com/c/abcd-1234"
fi
exit 0
EOF
chmod +x "$fake_chatgpt_send"

run_count=8
outs_file="$tmp/outs.txt"
: >"$outs_file"

for i in $(seq 1 "$run_count"); do
  out="$(CHATGPT_SEND_MAX_CDP_SLOTS=2 CHATGPT_SEND_SLOT_WAIT_TIMEOUT_SEC=30 "$SPAWN" \
    --project-path "$proj" \
    --task "slot test $i" \
    --iterations 1 \
    --launcher direct \
    --timeout-sec 60 \
    --log-dir "$log_dir" \
    --codex-bin "$fake_codex" \
    --chatgpt-send-path "$fake_chatgpt_send" \
    --browser-required 2>&1)"
  printf '%s\n---\n' "$out" >>"$outs_file"
done

python3 - "$outs_file" <<'PY'
import re
import sys
from pathlib import Path
import time

outs_path = Path(sys.argv[1])
raw = outs_path.read_text(encoding="utf-8")
blocks = [b.strip() for b in raw.split("\n---\n") if b.strip()]
entries = []
for b in blocks:
    log = None
    exf = None
    for line in b.splitlines():
        if line.startswith("LOG_FILE="):
            log = line.split("=", 1)[1].strip()
        if line.startswith("EXIT_FILE="):
            exf = line.split("=", 1)[1].strip()
    if log and exf:
        entries.append((Path(log), Path(exf)))

if not entries:
    raise SystemExit("no child entries parsed")

deadline = time.time() + 90.0
for _, exf in entries:
    while time.time() < deadline and not exf.exists():
        time.sleep(0.2)
    if not exf.exists():
        raise SystemExit(f"exit file missing: {exf}")

events = []
acq = 0
rel = 0
slot_ids = set()
for log, _ in entries:
    txt = log.read_text(encoding="utf-8", errors="replace")
    if "E_SLOT_ACQUIRE_TIMEOUT" in txt:
        raise SystemExit(f"slot timeout in {log}")
    for m in re.finditer(r"SLOT_ACQUIRE slot=(\d+) .*?ts_ms=(\d+)", txt):
        slot = int(m.group(1))
        ts = int(m.group(2))
        slot_ids.add(slot)
        acq += 1
        events.append((ts, 1))
    for m in re.finditer(r"SLOT_RELEASE slot=(\d+) .*?ts_ms=(\d+)", txt):
        slot = int(m.group(1))
        ts = int(m.group(2))
        slot_ids.add(slot)
        rel += 1
        events.append((ts, -1))

if acq == 0 or rel == 0:
    raise SystemExit("missing SLOT markers")
if acq != rel:
    raise SystemExit(f"acquire/release mismatch: {acq}!={rel}")
if any(s >= 2 for s in slot_ids):
    raise SystemExit(f"unexpected slot ids: {sorted(slot_ids)}")

# Release first on equal timestamps.
events.sort(key=lambda x: (x[0], x[1]))
inflight = 0
max_inflight = 0
for _, delta in events:
    inflight += delta
    if inflight < 0:
        raise SystemExit("negative inflight counter")
    max_inflight = max(max_inflight, inflight)

if max_inflight > 2:
    raise SystemExit(f"max inflight {max_inflight} exceeds slot limit 2")

print("OK")
PY

echo "OK"
