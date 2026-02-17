#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import contextlib
import importlib.util
import io
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


prompt = "Iteration 10/20. Проверка stale guard."
baseline = {
    "userCount": 7,
    "assistantCount": 3,
    "lastUser": "old user",
    "lastUserSig": "u-old",
    "lastAssistant": "old answer",
    "lastAssistantSig": "a-old",
    "stopVisible": False,
}

assert mod.should_skip_duplicate_send(prompt, {"lastUser": prompt}) is True
assert mod.should_skip_duplicate_send(prompt, {"lastUser": "другой текст"}) is False

# Phase-1 post-verify: echo success.
echo_states_ok = [
    {"userCount": 7, "assistantCount": 3, "lastUser": "old user", "lastUserSig": "u-old", "lastAssistant": "old answer", "lastAssistantSig": "a-old", "stopVisible": False},
    {"userCount": 8, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "old answer", "lastAssistantSig": "a-old", "stopVisible": False},
]
echo_ok = mod.wait_for_user_echo(FakeCDP(echo_states_ok), baseline, prompt, timeout_s=1.0)
assert echo_ok is not None, "expected user echo"
assert echo_ok["lastUserSig"] == "u-new"

# Phase-1 post-verify: echo miss.
echo_states_bad = [
    {"userCount": 8, "assistantCount": 3, "lastUser": "другой текст", "lastUserSig": "u-other", "lastAssistant": "old answer", "lastAssistantSig": "a-old", "stopVisible": False},
]
echo_bad = mod.wait_for_user_echo(FakeCDP(echo_states_bad), baseline, prompt, timeout_s=0.6)
assert echo_bad is None, "echo must fail for non-matching user text"

# Phase-2 post-verify: with anchor baseline, stale assistant must timeout.
anchor = {
    "userCount": 8,
    "assistantCount": 3,
    "lastUser": prompt,
    "lastUserSig": "u-new",
    "lastAssistant": "old answer",
    "lastAssistantSig": "a-old",
    "stopVisible": False,
}
stale_states = [
    {"userCount": 8, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "old answer", "lastAssistantSig": "a-old", "stopVisible": False},
]
err = io.StringIO()
with contextlib.redirect_stderr(err):
    try:
        mod.wait_for_response(FakeCDP(stale_states), anchor, timeout_s=1.0)
    except TimeoutError:
        pass
    else:
        raise AssertionError("expected TimeoutError for stale assistant")
assert "E_ACTIVITY_TIMEOUT" in err.getvalue(), err.getvalue()

# Positive case: assistant updates after anchor.
fresh_states = [
    {"userCount": 8, "assistantCount": 3, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "old answer", "lastAssistantSig": "a-old", "stopVisible": True},
    {"userCount": 8, "assistantCount": 4, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "new answer", "lastAssistantSig": "a-new", "stopVisible": False},
    {"userCount": 8, "assistantCount": 4, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "new answer", "lastAssistantSig": "a-new", "stopVisible": False},
    {"userCount": 8, "assistantCount": 4, "lastUser": prompt, "lastUserSig": "u-new", "lastAssistant": "new answer", "lastAssistantSig": "a-new", "stopVisible": False},
]
answer = mod.wait_for_response(FakeCDP(fresh_states), anchor, timeout_s=4.0)
assert answer == "new answer", answer

# Generation-in-progress marker.
gen_states = [
    {"hasEditor": True, "hasSend": False, "stopVisible": True},
    {"hasEditor": True, "hasSend": False, "stopVisible": False},
]
err2 = io.StringIO()
with contextlib.redirect_stderr(err2):
    saw = mod.wait_until_send_ready(FakeCDP(gen_states), timeout_s=2.0)
assert saw is True
assert "E_GENERATION_IN_PROGRESS" in err2.getvalue(), err2.getvalue()
assert "E_PRECHECK_GENERATION_IN_PROGRESS" in err2.getvalue(), err2.getvalue()

# Dispatch signal must not treat already-visible stop as a successful send.
dispatch_baseline_busy = {
    "userCount": 8,
    "assistantCount": 4,
    "lastUserSig": "u8",
    "lastAssistantSig": "a4",
    "stopVisible": True,
}
dispatch_busy_states = [
    {"userCount": 8, "assistantCount": 4, "lastUserSig": "u8", "lastAssistantSig": "a4", "stopVisible": True},
]
assert mod.wait_for_dispatch_signal(FakeCDP(dispatch_busy_states), dispatch_baseline_busy, max_wait_s=0.4) is False

dispatch_baseline_idle = {
    "userCount": 8,
    "assistantCount": 4,
    "lastUserSig": "u8",
    "lastAssistantSig": "a4",
    "stopVisible": False,
}
dispatch_new_activity = [
    {"userCount": 8, "assistantCount": 4, "lastUserSig": "u8", "lastAssistantSig": "a4", "stopVisible": True},
]
assert mod.wait_for_dispatch_signal(FakeCDP(dispatch_new_activity), dispatch_baseline_idle, max_wait_s=0.4) is True

# Stale stop guard: if stop is visible but message state does not change,
# precheck should treat it as stale and allow sending to continue.
orig_stale_sec = mod.STALE_STOP_SEC
orig_stale_poll = mod.STALE_STOP_POLL_SEC
mod.STALE_STOP_SEC = 0.2
mod.STALE_STOP_POLL_SEC = 0.02
try:
    stale_precheck_states = [
        {"hasEditor": True, "hasSend": False, "stopVisible": True},  # send-ready probe
        {"userCount": 8, "assistantCount": 4, "lastUserSig": "u8", "lastAssistantSig": "a4", "stopVisible": True},
    ]
    err3 = io.StringIO()
    with contextlib.redirect_stderr(err3):
        in_progress = mod.is_generation_in_progress(FakeCDP(stale_precheck_states))
    assert in_progress is False
    assert "E_STALE_STOP_ASSUME_IDLE" in err3.getvalue(), err3.getvalue()

    stale_wait_states = [
        {"hasEditor": True, "hasSend": False, "stopVisible": True},  # ready probe
        {"userCount": 8, "assistantCount": 4, "lastUserSig": "u8", "lastAssistantSig": "a4", "stopVisible": True},
    ]
    err4 = io.StringIO()
    with contextlib.redirect_stderr(err4):
        saw_stale = mod.wait_until_send_ready(FakeCDP(stale_wait_states), timeout_s=2.0)
    assert saw_stale is True
    assert "E_STALE_STOP_ASSUME_IDLE" in err4.getvalue(), err4.getvalue()
finally:
    mod.STALE_STOP_SEC = orig_stale_sec
    mod.STALE_STOP_POLL_SEC = orig_stale_poll

# Route guard: mismatch once, navigate, then correct chat id.
print("[NEGATIVE_EXPECTED] error_code=E_ROUTE_MISMATCH")
route_states_ok = [
    {"url": "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
    True,  # wait_for_composer probe
    {"hasEditor": True, "hasSend": True, "stopVisible": False},  # wait_send_ready probe
    {"url": "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},
]
route_cdp_ok = FakeCDP(route_states_ok)
route_ok = mod.ensure_target_route(route_cdp_ok, "https://chatgpt.com/c/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
assert route_ok is True

# Route guard: mismatch persists after one navigation.
print("[NEGATIVE_EXPECTED] error_code=E_ROUTE_MISMATCH")
route_states_bad = [
    {"url": "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
    True,
    {"hasEditor": True, "hasSend": True, "stopVisible": False},
    {"url": "https://chatgpt.com/c/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
]
route_cdp_bad = FakeCDP(route_states_bad)
route_bad = mod.ensure_target_route(route_cdp_bad, "https://chatgpt.com/c/cccccccc-cccc-cccc-cccc-cccccccccccc")
assert route_bad is False

# Precheck: duplicate prompt with ready assistant answer -> reuse.
precheck_states_ready = [
    {"url": "https://chatgpt.com/c/dddddddd-dddd-dddd-dddd-dddddddddddd"},
    {
        "userCount": 9,
        "assistantCount": 5,
        "lastUser": prompt,
        "lastUserSig": "u9",
        "lastAssistant": "already ready answer",
        "lastAssistantSig": "a5",
        "stopVisible": False,
    },
]
precheck_cdp_ready = FakeCDP(precheck_states_ready)
reused, reused_text, _ = mod.precheck_reply_before_send(
    precheck_cdp_ready,
    "https://chatgpt.com/c/dddddddd-dddd-dddd-dddd-dddddddddddd",
    prompt,
    timeout_s=2.0,
)
assert reused is True
assert reused_text == "already ready answer"

# Precheck: no matching ready reply -> no reuse.
precheck_states_none = [
    {"url": "https://chatgpt.com/c/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"},
    {
        "userCount": 10,
        "assistantCount": 5,
        "lastUser": "другой промпт",
        "lastUserSig": "u10",
        "lastAssistant": "old answer",
        "lastAssistantSig": "a5",
        "stopVisible": False,
    },
]
precheck_cdp_none = FakeCDP(precheck_states_none)
reused2, reused_text2, _ = mod.precheck_reply_before_send(
    precheck_cdp_none,
    "https://chatgpt.com/c/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
    prompt,
    timeout_s=2.0,
)
assert reused2 is False
assert reused_text2 == ""

print("T_e2e_stale_reply_guard: OK")
PY
