#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/score_stress_run.sh <stress_log1> [stress_log2 ...]

Example:
  scripts/score_stress_run.sh /tmp/chatgpt_send_stress/stress_iter_*.log
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

paths = []
for raw in sys.argv[1:]:
    p = Path(raw)
    if p.exists() and p.is_file():
        paths.append(p)

if not paths:
    print("No stress log files found", file=sys.stderr)
    raise SystemExit(2)

re_send = re.compile(r"phase=send event=dispatched|action=send")
re_route_error = re.compile(r"E_ROUTE_MISMATCH|CHAT_ROUTE=E_ROUTE_MISMATCH|E_MULTIPLE_CHAT_TABS_BLOCKED|E_CHAT_FINGERPRINT_MISMATCH|E_UI_NOT_READY")
re_unconfirmed_send = re.compile(r"E_POSTSEND_LAST_USER_MISMATCH|E_SEND_NOT_CONFIRMED")
re_no_blind = re.compile(r"E_NO_BLIND_RESEND")
re_fail = re.compile(r"RUN_END .*result=FAIL")
re_pass = re.compile(r"RUN_END .*result=PASS|ASSERT_OK")
re_evidence = re.compile(r"EVIDENCE_CAPTURED|EVIDENCE_AUTOCAPTURE|EVIDENCE_PARTIAL")
re_any_error = re.compile(r"\bE_[A-Z0-9_]+")

total = 0
passed = 0
failed = 0
wrong_chat_send = 0
blind_resend = 0
unexpected_send_unconfirmed = 0
fail_without_evidence = 0

for path in paths:
    text = path.read_text(encoding="utf-8", errors="ignore")
    total += 1
    has_send = bool(re_send.search(text))
    has_route_err = bool(re_route_error.search(text))
    has_unconfirmed_send = bool(re_unconfirmed_send.search(text))
    has_no_blind = bool(re_no_blind.search(text))
    has_fail = bool(re_fail.search(text))
    has_pass = bool(re_pass.search(text))
    has_evidence = bool(re_evidence.search(text))
    has_error = bool(re_any_error.search(text))

    if has_fail:
        failed += 1
    elif has_pass:
        passed += 1
    else:
        failed += 1

    if has_send and has_route_err:
        wrong_chat_send += 1
    if has_send and has_no_blind:
        blind_resend += 1
    if has_unconfirmed_send:
        unexpected_send_unconfirmed += 1
    if (has_fail or has_error) and not has_evidence:
        fail_without_evidence += 1

pass_rate = (passed / total) if total else 0.0
score = int(round(pass_rate * 100))
score -= wrong_chat_send * 30
score -= blind_resend * 20
score -= unexpected_send_unconfirmed * 10
score -= fail_without_evidence * 10
if score < 0:
    score = 0

print(
    "STRESS_SCORE "
    f"total={total} pass={passed} fail={failed} "
    f"wrong_chat_send={wrong_chat_send} blind_resend={blind_resend} "
    f"unexpected_send_unconfirmed={unexpected_send_unconfirmed} "
    f"fail_without_evidence={fail_without_evidence} score={score}"
)
print(f"SCORE={score}")
PY
