#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path

spec = importlib.util.spec_from_file_location("cdp_chatgpt", Path("/home/matrix/projects/chatgpt-send/bin/cdp_chatgpt.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeCDP:
    pass


orig_soft_reset = mod.soft_reset_tab
orig_precheck = mod.precheck_reply_before_send
try:
    mod.soft_reset_tab = lambda *_args, **_kwargs: True

    def fake_precheck(*_args, **_kwargs):
        st = {
            "assistantAfterLastUser": True,
            "lastAssistant": "already tracked answer",
            "lastAssistantSig": "a2",
            "lastUserSig": "u2",
            "assistantCount": 2,
            "userCount": 2,
        }
        return True, "already tracked answer", st

    mod.precheck_reply_before_send = fake_precheck
    stderr_buf = io.StringIO()
    with redirect_stderr(stderr_buf):
        reused, text, st = mod.try_reuse_after_echo_miss_reset(
            FakeCDP(),
            "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "prompt",
            timeout_s=30.0,
        )
finally:
    mod.soft_reset_tab = orig_soft_reset
    mod.precheck_reply_before_send = orig_precheck

err = stderr_buf.getvalue()
assert reused is True
assert text == "already tracked answer"
assert st.get("assistantAfterLastUser") is True
assert "E_RESEND_SKIPPED_IDEMPOTENT" in err, err
assert "RESEND_CONTROLLED" not in err, err

print("OK")
PY
