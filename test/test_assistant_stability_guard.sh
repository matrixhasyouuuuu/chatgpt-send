#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("cdp_chatgpt", Path("/home/matrix/projects/chatgpt-send/bin/cdp_chatgpt.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeCDP:
    def __init__(self, states):
        self.states = states
        self.i = 0

    def eval(self, expression, timeout=10.0):
        if self.i < len(self.states):
            st = self.states[self.i]
            self.i += 1
            return st
        return self.states[-1]

    def call(self, method, params=None, timeout=30.0):
        return {}


orig_stability = mod.ASSISTANT_STABILITY_SEC
orig_probe_stability = mod.ASSISTANT_PROBE_STABILITY_SEC
orig_poll = mod.ASSISTANT_STABILITY_POLL_SEC
mod.ASSISTANT_STABILITY_SEC = 0.05
mod.ASSISTANT_PROBE_STABILITY_SEC = 0.03
mod.ASSISTANT_STABILITY_POLL_SEC = 0.01

try:
    # 1) Stability helper: constantly changing assistant text -> unstable.
    unstable_states = [
        {"assistantAfterLastUser": True, "lastAssistant": "a1", "lastAssistantSig": "s1", "stopVisible": False},
        {"assistantAfterLastUser": True, "lastAssistant": "a2", "lastAssistantSig": "s2", "stopVisible": False},
        {"assistantAfterLastUser": True, "lastAssistant": "a3", "lastAssistantSig": "s3", "stopVisible": False},
    ]
    ok, st = mod.wait_for_assistant_stable_after_anchor(
        FakeCDP(unstable_states),
        timeout_s=0.06,
        quiet_sec=0.04,
    )
    assert ok is False, st

    # 2) Precheck should not return first partial chunk; it should wait for stable final chunk.
    prompt = "Iteration 99/99. Проверка полноты ответа."
    target_url = "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    precheck_states = [
        {"url": target_url},
        {
            "userCount": 5,
            "assistantCount": 3,
            "lastUser": prompt,
            "lastUserSig": "u5",
            "lastAssistant": "partial",
            "lastAssistantSig": "a1",
            "assistantAfterLastUser": True,
            "stopVisible": False,
        },
        {"userCount": 5, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u5", "lastAssistant": "partial", "lastAssistantSig": "a1", "assistantAfterLastUser": True, "stopVisible": False},
        {"userCount": 5, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u5", "lastAssistant": "partial+", "lastAssistantSig": "a2", "assistantAfterLastUser": True, "stopVisible": False},
        {"userCount": 5, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u5", "lastAssistant": "final full answer", "lastAssistantSig": "a3", "assistantAfterLastUser": True, "stopVisible": False},
        {"userCount": 5, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u5", "lastAssistant": "final full answer", "lastAssistantSig": "a3", "assistantAfterLastUser": True, "stopVisible": False},
        {"userCount": 5, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u5", "lastAssistant": "final full answer", "lastAssistantSig": "a3", "assistantAfterLastUser": True, "stopVisible": False},
    ]
    reused, text, _st = mod.precheck_reply_before_send(
        FakeCDP(precheck_states),
        target_url,
        prompt,
        timeout_s=1.0,
    )
    assert reused is True
    assert text == "final full answer", text
finally:
    mod.ASSISTANT_STABILITY_SEC = orig_stability
    mod.ASSISTANT_PROBE_STABILITY_SEC = orig_probe_stability
    mod.ASSISTANT_STABILITY_POLL_SEC = orig_poll

print("OK")
PY
