from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Dict, Any, List, Tuple
import re

ErrorClass = str
BlockReason = str
RecommendedAction = str


@dataclass(frozen=True)
class ErrorSpec:
    code: str
    cls: ErrorClass
    block: BlockReason
    title: str
    why: str
    recommended: Tuple[RecommendedAction, ...]
    safe_to_autostep: bool
    evidence_keys: Tuple[str, ...] = ()
    tags: Tuple[str, ...] = ()
    aliases: Tuple[str, ...] = ()


ERROR_REGISTRY_V1: Dict[str, ErrorSpec] = {
    "E_ROUTE_MISMATCH": ErrorSpec(
        code="E_ROUTE_MISMATCH",
        cls="ROUTING",
        block="HARD_BLOCK_USER",
        title="Active tab does not match target work chat",
        why="Strict routing check failed; sending is unsafe until the correct chat is active.",
        recommended=("RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("active_url", "target_url", "route_probe", "tab_fingerprint"),
        tags=("strict_single_chat", "routing"),
        aliases=("E_STRICT_CHAT_MISMATCH", "E_CHAT_MISMATCH", "E_MULTIPLE_CHAT_TABS_BLOCKED"),
    ),
    "E_NEW_CHAT_GUARD": ErrorSpec(
        code="E_NEW_CHAT_GUARD",
        cls="ROUTING",
        block="HARD_BLOCK_USER",
        title="New chat creation prevented",
        why="UI state indicates risk of creating a new chat; blocked to prevent misrouting.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("ui_snapshot", "active_url"),
        tags=("routing", "new_chat_prevent"),
        aliases=("E_PREVENT_NEW_CHAT", "E_NEW_CHAT_PREVENTED"),
    ),
    "E_TARGET_UNRESOLVED": ErrorSpec(
        code="E_TARGET_UNRESOLVED",
        cls="ROUTING",
        block="HARD_BLOCK_USER",
        title="Target chat not resolved",
        why="The tool could not resolve a unique target chat identity (URL/key).",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("target_hint", "active_url"),
        tags=("routing",),
        aliases=("E_TARGET_CHAT_REQUIRED",),
    ),
    "E_ACK_REQUIRED": ErrorSpec(
        code="E_ACK_REQUIRED",
        cls="INPUT",
        block="HARD_BLOCK_USER",
        title="Acknowledgement required",
        why="Safety acknowledgement is required before proceeding.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("ack_policy",),
        tags=("ack",),
        aliases=("E_ACK_MISSING", "E_REPLY_UNACKED_BLOCK_SEND"),
    ),
    "E_CDP_DOWN": ErrorSpec(
        code="E_CDP_DOWN",
        cls="ENV",
        block="HARD_BLOCK_ENV",
        title="CDP endpoint unreachable",
        why="Cannot connect to Chrome DevTools Protocol; automation is unavailable.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("cdp_probe",),
        tags=("env", "cdp"),
        aliases=("E_CDP_UNREACHABLE", "E_CHROME_NOT_RUNNING"),
    ),
    "E_PROFILE_MISSING": ErrorSpec(
        code="E_PROFILE_MISSING",
        cls="ENV",
        block="HARD_BLOCK_ENV",
        title="Chrome profile not found/accessible",
        why="Configured Chrome profile path is missing or has permission issues.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("profile_path",),
        tags=("env",),
        aliases=(),
    ),
    "E_STALE_LOCK": ErrorSpec(
        code="E_STALE_LOCK",
        cls="CONCURRENCY",
        block="SOFT_BLOCK_RECOVER",
        title="Stale lock detected",
        why="Lock appears stale or owned by a dead run; safe recovery can clean it up.",
        recommended=("STEP_RECOVER", "RUN_STATUS", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("lock_info", "pid_probe"),
        tags=("lock", "stale"),
        aliases=("E_LOCK_HELD", "E_LOCK_BUSY", "E_CHAT_SINGLE_FLIGHT_TIMEOUT"),
    ),
    "E_SLOT_BUSY": ErrorSpec(
        code="E_SLOT_BUSY",
        cls="CONCURRENCY",
        block="SOFT_BLOCK_RECOVER",
        title="All CDP slots busy",
        why="No free slot; safe recovery can reclaim stale slot or instruct to wait.",
        recommended=("RUN_STATUS", "STEP_RECOVER", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("slot_table",),
        tags=("slot",),
        aliases=("E_NO_FREE_SLOT",),
    ),
    "E_PID_MISMATCH": ErrorSpec(
        code="E_PID_MISMATCH",
        cls="CONCURRENCY",
        block="SOFT_BLOCK_RECOVER",
        title="PID artifact mismatch",
        why="State references a PID that does not match current owner; recovery can reconcile.",
        recommended=("STEP_RECOVER", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("pid_probe", "state_ref"),
        tags=("pid", "stale"),
        aliases=("E_STALE_PID_ARTIFACT",),
    ),
    "E_UI_NOT_READY": ErrorSpec(
        code="E_UI_NOT_READY",
        cls="UI_STATE",
        block="SOFT_BLOCK_RETRYABLE",
        title="UI not ready for safe send",
        why="Composer or critical DOM markers are missing or unstable; preflight or retry needed.",
        recommended=("STEP_PREFLIGHT", "STEP_COMPOSER_READY", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("ui_probe", "dom_markers"),
        tags=("ui",),
        aliases=("E_COMPOSER_NOT_READY", "E_PRECHECK_NO_NEW_REPLY"),
    ),
    "E_SEND_BUTTON_DISABLED": ErrorSpec(
        code="E_SEND_BUTTON_DISABLED",
        cls="UI_STATE",
        block="SOFT_BLOCK_RETRYABLE",
        title="Send button disabled",
        why="Send action is not available (empty composer or UI state).",
        recommended=("STEP_COMPOSER_READY", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("ui_probe",),
        tags=("ui",),
        aliases=(),
    ),
    "E_SELECTOR_DRIFT": ErrorSpec(
        code="E_SELECTOR_DRIFT",
        cls="UI_STATE",
        block="SOFT_BLOCK_RETRYABLE",
        title="UI selector drift detected",
        why="UI structure changed; probes failed to locate expected elements.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("ui_snapshot", "dom_markers"),
        tags=("ui", "selectors"),
        aliases=(),
    ),
    "E_TIMEOUT_BUDGET": ErrorSpec(
        code="E_TIMEOUT_BUDGET",
        cls="TIMEOUT",
        block="SOFT_BLOCK_RECOVER",
        title="Timeout budget exceeded",
        why="A stage exceeded its time budget; safe recovery or wait strategy may apply.",
        recommended=("STEP_RECOVER", "STEP_WAIT_STARTED", "STEP_WAIT_FINISHED", "RUN_EXPLAIN"),
        safe_to_autostep=True,
        evidence_keys=("stage_timing", "stop_visible", "last_markers"),
        tags=("timeout",),
        aliases=("E_WAIT_TIMEOUT", "E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE", "E_REPLY_WAIT_TIMEOUT_NO_ACTIVITY"),
    ),
    "E_ASSISTANT_NO_START": ErrorSpec(
        code="E_ASSISTANT_NO_START",
        cls="TIMEOUT",
        block="SOFT_BLOCK_RECOVER",
        title="Assistant did not start",
        why="Send may be confirmed but assistant start marker was not observed; recovery may help.",
        recommended=("STEP_RECOVER", "STEP_WAIT_STARTED", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("assistant_markers", "last_markers"),
        tags=("timeout", "assistant"),
        aliases=(),
    ),
    "E_ASSISTANT_STUCK": ErrorSpec(
        code="E_ASSISTANT_STUCK",
        cls="TIMEOUT",
        block="SOFT_BLOCK_WAIT",
        title="Assistant appears to be still generating",
        why="Generating indicator remains active; waiting is the safest action.",
        recommended=("STEP_WAIT_FINISHED", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("stop_visible", "assistant_markers"),
        tags=("assistant", "wait"),
        aliases=("E_REPLY_WAIT_TIMEOUT_STOP_VISIBLE",),
    ),
    "E_CHECKPOINT_MISSING": ErrorSpec(
        code="E_CHECKPOINT_MISSING",
        cls="PROTOCOL",
        block="SOFT_BLOCK_RECOVER",
        title="Required checkpoint missing",
        why="Protocol expected a checkpoint but it is absent or corrupt; recovery can rebuild safely.",
        recommended=("STEP_RECOVER", "RUN_EXPLAIN"),
        safe_to_autostep=True,
        evidence_keys=("checkpoint_ref", "run_dir"),
        tags=("protocol",),
        aliases=("E_PROTOCOL_CHECKPOINT_MISSING",),
    ),
    "E_EVIDENCE_REQUIRED_MISSING": ErrorSpec(
        code="E_EVIDENCE_REQUIRED_MISSING",
        cls="PROTOCOL",
        block="SOFT_BLOCK_RECOVER",
        title="Required evidence missing",
        why="Evidence required by protocol was not recorded; investigate and recover.",
        recommended=("RUN_EXPLAIN", "STEP_RECOVER"),
        safe_to_autostep=True,
        evidence_keys=("evidence_dir", "run_dir"),
        tags=("evidence", "protocol"),
        aliases=(),
    ),
    "E_SOFT_RESET_APPLIED": ErrorSpec(
        code="E_SOFT_RESET_APPLIED",
        cls="RECOVERY",
        block="NO_BLOCK",
        title="Soft reset applied successfully",
        why="Recovery succeeded; next step can proceed normally.",
        recommended=("STEP_READ", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("recovery_markers",),
        tags=("recovery",),
        aliases=(),
    ),
    "E_SOFT_RESET_FAILED": ErrorSpec(
        code="E_SOFT_RESET_FAILED",
        cls="RECOVERY",
        block="SOFT_BLOCK_RECOVER",
        title="Soft reset failed",
        why="UI/CDP recovery attempt did not complete; a fresh recovery/read-only validation is needed.",
        recommended=("RUN_EXPLAIN", "STEP_RECOVER", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("recovery_markers", "ui_snapshot", "cdp_probe"),
        tags=("recovery", "timeout"),
        aliases=(),
    ),
    "E_SEND_RETRY_VETO_INTRA_RUN": ErrorSpec(
        code="E_SEND_RETRY_VETO_INTRA_RUN",
        cls="RECOVERY",
        block="SOFT_BLOCK_RECOVER",
        title="Retry send blocked inside the same run",
        why="A previous dispatch may have already delivered the prompt, so automatic resend inside the same run was vetoed for safety.",
        recommended=("RUN_STATUS", "RUN_EXPLAIN", "STEP_WAIT_FINISHED"),
        safe_to_autostep=False,
        evidence_keys=("protocol_jsonl", "fetch_last", "ops_snapshot"),
        tags=("recovery", "dedupe", "no_resend"),
        aliases=(),
    ),
    "E_PROMPT_NOT_CONFIRMED_NO_RESEND": ErrorSpec(
        code="E_PROMPT_NOT_CONFIRMED_NO_RESEND",
        cls="RECOVERY",
        block="SOFT_BLOCK_RECOVER",
        title="Delivery could not be confirmed; resend blocked by safety policy",
        why="After timeout, the system could not confirm prompt presence and intentionally stopped without resending to avoid duplicates.",
        recommended=("RUN_STATUS", "RUN_EXPLAIN"),
        safe_to_autostep=False,
        evidence_keys=("protocol_jsonl", "fetch_last", "ops_snapshot"),
        tags=("recovery", "dedupe", "confirm_only", "availability_cost"),
        aliases=(),
    ),
    "E_CONFIRM_FETCH_LAST_FAILED": ErrorSpec(
        code="E_CONFIRM_FETCH_LAST_FAILED",
        cls="ENV",
        block="HARD_BLOCK_ENV",
        title="Failed to confirm chat state after timeout",
        why="Read-only fetch_last confirmation failed in confirm-only mode, so the run stopped fail-closed without resending.",
        recommended=("RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("cdp_probe", "protocol_jsonl", "fetch_last"),
        tags=("env", "recovery", "confirm_only", "fail_closed"),
        aliases=(),
    ),
    "E_CDP_TIMEOUT_RETRY": ErrorSpec(
        code="E_CDP_TIMEOUT_RETRY",
        cls="TIMEOUT",
        block="SOFT_BLOCK_RECOVER",
        title="Timeout retry recovery path engaged",
        why="Runtime.evaluate timeout triggered recovery logic; the next action depends on confirm-only/dedupe results.",
        recommended=("RUN_EXPLAIN", "RUN_STATUS"),
        safe_to_autostep=False,
        evidence_keys=("stage_timing", "protocol_jsonl", "ops_snapshot"),
        tags=("timeout", "recovery"),
        aliases=(),
    ),
    "E_PREFLIGHT_STALE": ErrorSpec(
        code="E_PREFLIGHT_STALE",
        cls="UI_STATE",
        block="SOFT_BLOCK_RETRYABLE",
        title="Fresh preflight required before delegated send",
        why="UI/chat state may have changed since the last read-only preflight, so delegated send is blocked until a fresh preflight is collected.",
        recommended=("STEP_PREFLIGHT", "RUN_STATUS", "RUN_EXPLAIN"),
        safe_to_autostep=True,
        evidence_keys=("status_ref", "checkpoint_ref", "route_probe"),
        tags=("facade", "preflight", "freshness"),
        aliases=(),
    ),
}


FALLBACK_RULES_V1: List[Tuple[re.Pattern, Dict[str, Any]]] = [
    (re.compile(r"^E_(ROUTE|CHAT|STRICT|TARGET|MULTIPLE_CHAT)_"), dict(
        cls="ROUTING",
        block="HARD_BLOCK_USER",
        title="Routing safety block",
        why="Routing-related error; sending is unsafe until the user resolves the correct target chat.",
        recommended=("RUN_STATUS", "RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("active_url", "target_url"),
        tags=("routing",),
    )),
    (re.compile(r"^E_(ACK|INPUT|ARG|DUPLICATE_PROMPT)_"), dict(
        cls="INPUT",
        block="HARD_BLOCK_USER",
        title="Input/acknowledgement required",
        why="User input or acknowledgement is required before proceeding.",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("ack_policy",),
        tags=("input",),
    )),
    (re.compile(r"^E_(CDP|CHROME|ENV|PROFILE|NET|LOGIN|CLOUDFLARE)_"), dict(
        cls="ENV",
        block="HARD_BLOCK_ENV",
        title="Environment error",
        why="Automation environment is not ready (CDP/Chrome/profile/network/login/challenge).",
        recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
        safe_to_autostep=False,
        evidence_keys=("cdp_probe", "ui_snapshot"),
        tags=("env",),
    )),
    (re.compile(r"^E_(LOCK|SLOT|PID|STALE|CONC)_"), dict(
        cls="CONCURRENCY",
        block="SOFT_BLOCK_RECOVER",
        title="Concurrency/state artifact issue",
        why="Lock/slot/pid artifact issue; safe recovery is likely available.",
        recommended=("STEP_RECOVER", "RUN_STATUS", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("lock_info", "slot_table", "pid_probe"),
        tags=("concurrency",),
    )),
    (re.compile(r"^E_(UI|COMPOSER|SEND_BUTTON|SELECTOR|PRECHECK|PROMPT_NOT_FOUND)_"), dict(
        cls="UI_STATE",
        block="SOFT_BLOCK_RETRYABLE",
        title="UI readiness issue",
        why="UI not ready or selectors drifted; preflight/retry or explain may be needed.",
        recommended=("STEP_PREFLIGHT", "STEP_COMPOSER_READY", "RETRY_SAME_STEP"),
        safe_to_autostep=True,
        evidence_keys=("ui_probe", "dom_markers"),
        tags=("ui",),
    )),
    (re.compile(r"^E_(TIMEOUT|WAIT|ASSISTANT|REPLY_WAIT)_"), dict(
        cls="TIMEOUT",
        block="SOFT_BLOCK_RECOVER",
        title="Timeout/wait issue",
        why="A stage exceeded time budget or assistant lifecycle marker was not observed.",
        recommended=("STEP_WAIT_FINISHED", "STEP_RECOVER", "RUN_STATUS"),
        safe_to_autostep=True,
        evidence_keys=("stage_timing", "stop_visible"),
        tags=("timeout",),
    )),
    (re.compile(r"^E_(PROTOCOL|CHECKPOINT|EVIDENCE)_"), dict(
        cls="PROTOCOL",
        block="SOFT_BLOCK_RECOVER",
        title="Protocol/checkpoint issue",
        why="Protocol expected data (checkpoint/evidence) that is missing or inconsistent.",
        recommended=("RUN_EXPLAIN", "STEP_RECOVER"),
        safe_to_autostep=True,
        evidence_keys=("checkpoint_ref", "evidence_dir"),
        tags=("protocol",),
    )),
    (re.compile(r"^W_(REPLY_LATE|SOFT_RESET|POSTSEND)_"), dict(
        cls="RECOVERY",
        block="NO_BLOCK",
        title="Recovery warning",
        why="Recovery path was used but may still have succeeded.",
        recommended=("RUN_STATUS",),
        safe_to_autostep=True,
        evidence_keys=("evidence_dir",),
        tags=("recovery", "warning"),
    )),
]


def resolve_error_spec_with_meta(error_code: Optional[str]) -> Optional[Dict[str, Any]]:
  if not error_code:
    return None

  error_code = str(error_code).strip()
  if not error_code:
    return None

  if error_code in ERROR_REGISTRY_V1:
    return {"spec": ERROR_REGISTRY_V1[error_code], "match_kind": "exact"}

  for spec in ERROR_REGISTRY_V1.values():
    if error_code in spec.aliases:
      return {"spec": spec, "match_kind": "alias"}

  for pattern, tmpl in FALLBACK_RULES_V1:
    if pattern.match(error_code):
      return {"spec": ErrorSpec(
          code=error_code,
          cls=tmpl["cls"],
          block=tmpl["block"],
          title=tmpl["title"],
          why=tmpl["why"],
          recommended=tuple(tmpl["recommended"]),
          safe_to_autostep=bool(tmpl["safe_to_autostep"]),
          evidence_keys=tuple(tmpl.get("evidence_keys", ())),
          tags=tuple(tmpl.get("tags", ())),
          aliases=(),
      ), "match_kind": "fallback"}

  return {"spec": ErrorSpec(
      code=error_code,
      cls="INTERNAL",
      block="UNKNOWN_BLOCK",
      title="Unknown error",
      why="Error code is not recognized by the facade registry; inspect evidence and explain output.",
      recommended=("RUN_EXPLAIN", "ABORT_SAFE"),
      safe_to_autostep=False,
      evidence_keys=(),
      tags=("unknown",),
      aliases=(),
  ), "match_kind": "default"}


def resolve_error_spec(error_code: Optional[str]) -> Optional[ErrorSpec]:
  meta = resolve_error_spec_with_meta(error_code)
  if not meta:
    return None
  spec = meta.get("spec")
  return spec if isinstance(spec, ErrorSpec) else None
