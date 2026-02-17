#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("cdp_chatgpt", Path("/home/matrix/projects/chatgpt-send/bin/cdp_chatgpt.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeCDP:
    def __init__(self):
        self.eval_calls = 0

    def eval(self, expression, timeout=10.0):
        self.eval_calls += 1
        return {}


cdp = FakeCDP()
calls = {"soft_reset": 0, "precheck": 0}
orig_soft_reset = mod.soft_reset_tab
orig_precheck = mod.precheck_reply_before_send
try:
    def fake_soft_reset(cdp_obj, target_url, reason, timeout_s=60.0):
        calls["soft_reset"] += 1
        assert target_url.startswith("https://chatgpt.com/c/")
        assert reason == "echo_miss_post_verify"
        return True

    def fake_precheck(cdp_obj, target_url, prompt, timeout_s):
        calls["precheck"] += 1
        st = {
            "userCount": 2,
            "assistantCount": 2,
            "lastUserSig": "u2",
            "lastAssistantSig": "a2",
            "lastAssistant": "ready from precheck",
            "assistantAfterLastUser": True,
        }
        return True, "ready from precheck", st

    mod.soft_reset_tab = fake_soft_reset
    mod.precheck_reply_before_send = fake_precheck

    reused, text, st = mod.try_reuse_after_echo_miss_reset(
        cdp, "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "prompt", timeout_s=30.0
    )
finally:
    mod.soft_reset_tab = orig_soft_reset
    mod.precheck_reply_before_send = orig_precheck

assert reused is True
assert text == "ready from precheck"
assert st.get("assistantAfterLastUser") is True
assert calls["soft_reset"] == 1, calls
assert calls["precheck"] == 1, calls
assert cdp.eval_calls == 0, "reuse path should not resend prompt"

print("OK")
PY
