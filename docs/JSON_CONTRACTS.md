# JSON Contracts (`status.v1`, `explain.v1`, `step.v1`)

This document describes the machine-facing JSON outputs intended for AI/CLI integrations.

## 1) `status.v1` (`chatgpt_send --status --json`)

Purpose: current routing/CDP/ack/tabs/last-run state.

Top-level fields (current):

- `schema_version`: `status.v1`
- `ts`: unix timestamp
- `status`: `ready|degraded|blocked`
- `can_send`: `0|1`
- `blockers`: string array
- `warnings`: string array
- `next_actions`: human next-step hints
- `multi_tabs`: structured multi-tab status
- `ops`: live ops snapshot (CDP/route/chat/tabs/pending/ledger...)
- `checkpoint`: last checkpoint snapshot (`state/last_specialist_checkpoint.json`)
- `latest_run`: latest run summary metadata
- `operator_summary`: normalized one-line machine/operator summary (`state/why/next/note/confidence`)

### `multi_tabs` (structured)

- `present`: `bool`
- `tab_count`: `int`
- `severity`: `none|warning|block`
- `reason`: short machine tag (for example `route_ok_multiple_tabs`)
- `hint`: short operator-friendly message

Notes:

- `multi_tabs.severity=warning` can coexist with `can_send=1` when strict routing is already proven.
- The send core still applies its own routing guards.

### `operator_summary` (MUST-HAVE facade summary)

- `state`: `READY|WAITING|RECOVERABLE|BLOCKED|ERROR`
- `why`: normalized short reason key (for example `ok_ready`, `ack_required`, `pending_cycle`)
- `next`: next action id / control step (for example `STEP_READ`, `STEP_WAIT_FINISHED`, `ACK`, `RUN_EXPLAIN`)
- `note`: one-line human explanation
- `confidence`: `high|med|low`

## 2) `explain.v1` (`chatgpt_send --explain <target> --json`)

Purpose: explain an error code or a specific/latest run in human+machine form.

Top-level fields (current):

- `schema_version`: `explain.v1`
- `ts`
- `target`
- `target_kind`: `error_code|run`
- `run_dir`
- `run_id`
- `run_outcome`
- `error_code`
- `error_class`
- `block_reason`
- `error`: normalized error object (when available)
- `error_spec`: resolved registry spec (when available)
- `what`: short explanation
- `auto_actions`: what the tool already did
- `next_actions`: recommended next actions (merged registry + runtime context)
- `evidence`: list of useful files with hints
- `details`: raw run evidence objects (manifest/summary/contract/probe/fetch_last/ops_snapshot)
- `operator_summary`: normalized summary of current explain outcome (`state/why/next/...`)

Typical use:

- after non-zero exit from send pipeline
- after `step` returned blocked/no-op and you want context
- for a known `E_*` code (`chatgpt_send --explain E_PREFLIGHT_STALE --json`)

## 3) `step.v1` (`chatgpt_send step read --json`)

Purpose: read-only planner over current state, with next safe action and gates.

Top-level fields (current, key ones):

- `schema_version`: `step.v1`
- `schema`: `step.v1` (legacy duplicate field; keep tolerant parsers)
- `generated_at`
- `summary`
- `operator_summary` (MUST-HAVE top-level API summary)
- `run_context`
- `intent`
- `result`
- `state`
- `preflight`
- `block` (nullable)
- `next`
- `decision`
- `auto` (present for `step auto --json`, bounded executor metadata)
- `refs`
- `hints`
- `actions`
- `artifacts`

### `decision` (primary machine control point)

- `block_reason`: planner block class (`NO_BLOCK`, `SOFT_BLOCK_*`, `HARD_BLOCK_*`, ...)
- `safe_to_autostep`: bool
- `error`: normalized planner error (or `null`)
- `recommended_actions`: structured action list
- `next`:
  - `action_id` (primary next step)
  - `why_now`
  - `gates` (string array; machine-checkable hints)

`step.v1` consistency rule:

- `operator_summary.next == decision.next.action_id`

Examples of `action_id`:

- `RUN_STATUS`
- `RUN_EXPLAIN`
- `STEP_PREFLIGHT` (means rerun `step read --json`)
- `STEP_WAIT_FINISHED`
- `STEP_RECOVER`
- `DELEGATE_SEND_PIPELINE`

### `preflight` (freshness gating context)

- `token_path`
- `ttl_sec`
- `fresh` (`bool`)
- `reason_not_fresh` (`missing|expired|target_mismatch|tab_fingerprint_mismatch|...`)
- `last_ok_at`
- `age_sec`
- `current`: target/fingerprint/checkpoint/status_ts
- `token`: last preflight token snapshot

Delegated send should not be attempted when `preflight.fresh=false`.

### `auto` (bounded auto executor metadata; `step auto --json`)

- `requested_max_steps`
- `steps_executed`
- `actions_executed[]`
- `stop_reason` (for example `blocked`, `need_send`, `need_safe_action`, `forbidden_action`, `max_steps_reached`)
- `forbidden_action_detected` (action id or empty string)

Current MVP policy: `step auto` is bounded and does not execute delegated send.

### `state.multi_tabs`

Structured multi-tab info mirrored into planner state:

- `present`
- `severity`
- `tab_count`
- `reason`
- `hint`

### `decision.next.gates` (string gates)

Current gates include (examples):

- `strict_single_chat_passed=true|false|unknown`
- `cdp_ok=true|false`
- `ack_ok=true|false`
- `status_partial=true|false`
- `message_present=true|false`
- `preflight_fresh=true|false`
- `multi_tabs_present=true|false`
- `multi_tabs_severity=none|warning|block`
- `checkpoint_stage=<stage|null>`

Use these as hints, not as a substitute for the actual `decision.next.action_id`.

## Compatibility guidance for AI agents

- Parse JSON defensively (unknown fields may be added).
- Prefer:
  - `schema_version`
  - `decision.next.action_id`
  - `block.error_code`
  - `preflight.fresh`
  - `multi_tabs.severity`
- Ignore fields you do not need.
- Do not hard-fail if extra fields appear.
