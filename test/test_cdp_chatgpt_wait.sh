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


baseline = {
    "userCount": 5,
    "assistantCount": 5,
    "lastAssistant": "CHILD_FLOW_OK",
    "lastAssistantSig": "sig-old",
    "stopVisible": False,
}

# Case 1: no counter growth and identical final text, but Stop button appears.
states_stop = [
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "CHILD_FLOW_OK", "lastAssistantSig": "sig-old", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "CHILD_FLOW_OK", "lastAssistantSig": "sig-old", "stopVisible": True},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "CHILD_FLOW_OK", "lastAssistantSig": "sig-old", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "CHILD_FLOW_OK", "lastAssistantSig": "sig-old", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "CHILD_FLOW_OK", "lastAssistantSig": "sig-old", "stopVisible": False},
]
answer1 = mod.wait_for_response(FakeCDP(states_stop), baseline, 4.0)
assert answer1 == "CHILD_FLOW_OK", answer1

# Case 2: no counter growth and no Stop button, but assistant signature changes.
states_sig = [
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "old", "lastAssistantSig": "sig-old", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "new answer", "lastAssistantSig": "sig-new", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "new answer", "lastAssistantSig": "sig-new", "stopVisible": False},
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "new answer", "lastAssistantSig": "sig-new", "stopVisible": False},
]
answer2 = mod.wait_for_response(FakeCDP(states_sig), baseline, 4.0)
assert answer2 == "new answer", answer2

# Case 3: no activity at all must still timeout.
states_idle = [
    {"userCount": 5, "assistantCount": 5, "lastAssistant": "old", "lastAssistantSig": "sig-old", "stopVisible": False},
]
try:
    mod.wait_for_response(FakeCDP(states_idle), baseline, 1.2)
except TimeoutError:
    pass
else:
    raise AssertionError("expected TimeoutError for idle state")

# Case 4: CDP.call must timeout even on endless event stream without matching id.
class FakeWS:
    def __init__(self):
        self.sent = []

    def send(self, payload):
        self.sent.append(payload)

    def settimeout(self, value):
        pass

    def recv(self):
        # Event packet without "id" (won't match request id).
        return '{"method":"Runtime.consoleAPICalled","params":{"type":"log"}}'

cdp = mod.CDP.__new__(mod.CDP)
cdp.ws = FakeWS()
cdp.next_id = 1
try:
    cdp.call("Runtime.enable", timeout=0.3)
except TimeoutError:
    pass
else:
    raise AssertionError("expected TimeoutError for CDP.call event-only stream")

print("OK")
PY
