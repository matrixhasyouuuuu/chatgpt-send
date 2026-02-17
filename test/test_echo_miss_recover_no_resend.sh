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
        self.calls = []
        self.state_calls = 0

    def eval(self, expression, timeout=10.0):
        self.calls.append(expression)
        if "scrollIntoView" in expression:
            return {"ok": True, "hasEditor": True, "hasSend": True, "stopVisible": False}
        if 'data-message-author-role="user"' in expression:
            self.state_calls += 1
            if self.state_calls == 1:
                return {
                    "userCount": 1,
                    "lastUserSig": "u1",
                    "lastUser": "old prompt",
                    "assistantCount": 1,
                    "lastAssistantSig": "a1",
                    "lastAssistant": "old answer",
                    "stopVisible": False,
                }
            return {
                "userCount": 2,
                "lastUserSig": "u2",
                "lastUser": "new prompt",
                "assistantCount": 1,
                "lastAssistantSig": "a1",
                "lastAssistant": "old answer",
                "stopVisible": False,
            }
        raise AssertionError("unexpected eval expression")


baseline = {
    "userCount": 1,
    "lastUserSig": "u1",
    "lastUser": "old prompt",
    "assistantCount": 1,
    "lastAssistantSig": "a1",
    "lastAssistant": "old answer",
    "stopVisible": False,
}

cdp = FakeCDP()
orig_wait_until_send_ready = mod.wait_until_send_ready
orig_sleep = mod.time.sleep
try:
    mod.wait_until_send_ready = lambda *_args, **_kwargs: False
    mod.time.sleep = lambda _s: None
    recovered = mod.recover_user_echo_after_miss(cdp, baseline, "new prompt", timeout_s=5.0)
finally:
    mod.wait_until_send_ready = orig_wait_until_send_ready
    mod.time.sleep = orig_sleep

assert recovered is not None, "expected recovered echo state"
assert int(recovered.get("userCount") or 0) == 2, recovered
assert all("insertText" not in expr for expr in cdp.calls), "recover path must not resend prompt"
assert any("scrollIntoView" in expr for expr in cdp.calls), "focus+scroll recover JS was not called"

print("OK")
PY
