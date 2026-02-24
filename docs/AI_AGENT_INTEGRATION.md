# AI Agent Integration Guide

This guide is for another CLI/AI agent that wants to control `chatgpt_send` safely.

## Goal

Use ChatGPT Web as a visible “Specialist” while your agent stays in the terminal and avoids duplicate sends, wrong-tab sends, and stale-UI decisions.

## Coordinator + Swarm workflow (this team's preferred mode)

In this repository, a strong pattern is:

- main agent = coordinator / control point
- child agents = parallel executors (patches, tests, review, verification)
- Specialist = external thinking/checkpoint via browser

The coordinator is the "mechanism" that decides:

- how many child agents to launch
- how to split the task
- who does what
- how to reconcile overlaps/conflicts
- what to verify before reporting completion

This is a **soft swarm** approach (shared context + coordination), not hard code partitioning.

## Use the UX facade (not low-level scripts)

Preferred commands:

```bash
chatgpt_send --status --json
chatgpt_send --explain latest --json
chatgpt_send step read --json
chatgpt_send step send --message "..."
chatgpt_send --ack
```

Why:

- `status` gives current route/CDP/ack/tabs state
- `step read` gives a planner (`step.v1`) with next safe action
- `explain` translates run/error states into human+machine next steps
- `step send` delegates to the existing guarded core pipeline
- `step auto` is a bounded facade helper (safe/whitelisted steps only; no delegated send)

## Minimal safe loop (JSON-driven)

1. Read `status`:

```bash
chatgpt_send --status --json
```

2. Build plan:

```bash
chatgpt_send step read --json
```

3. Inspect `step.v1`:

- `decision.next.action_id`
- `decision.next.gates`
- `block.reason` / `block.error_code`
- `preflight`
- `state.multi_tabs`

4. If allowed and you have a message:

```bash
chatgpt_send step send --message "..."
```

5. If blocked/failure:

```bash
chatgpt_send --explain latest --json
```

6. If unread reply is pending, acknowledge after reading:

```bash
chatgpt_send --ack
```

## Canonical Agent Loop (v1)

Use `operator_summary` as the primary control surface.

1. `chatgpt_send --status --json`
2. Read `status.operator_summary` (`state`, `why`, `next`, `confidence`)
3. If `state=READY` and `next=STEP_READ`:
   - run `chatgpt_send step read --json`
   - read `step.operator_summary.next` (must match `decision.next.action_id`)
4. Follow `next`:
   - `ACK` -> `chatgpt_send --ack`
   - `STEP_READ` / `STEP_PREFLIGHT` -> `chatgpt_send step read --json`
   - `STEP_WAIT_FINISHED` / `STEP_RECOVER` -> `chatgpt_send step auto --max-steps 1`
   - `DELEGATE_SEND_PIPELINE` -> `chatgpt_send step send --message "..."` (not `step auto`)
   - `RUN_STATUS` -> `chatgpt_send --status --json`
   - `RUN_EXPLAIN` -> `chatgpt_send --explain latest --json`
   - `ABORT_SAFE` -> stop and request human intervention
5. If `state=BLOCKED|ERROR`, run `explain` before any mutating action.
6. Do not bypass `operator_summary`/`decision.next` with internal flags or raw logs.

## Swarm child tasking (soft coordination)

When using `bin/spawn_second_agent`, pass swarm context so children can coordinate without hard locks:

- `--agent-id <id>`
- `--agent-name <name>`
- `--team-goal "<shared goal>"`
- `--peer "<agent-x: what they are doing>"` (repeatable)

The child prompt should communicate:

- shared goal
- this child's exact task
- who else is doing what
- rule: if overlap is detected, do not blindly duplicate; switch to validation/integration/fixups and report overlap

For coordinator-friendly aggregation, require child outputs to include:

- `CHILD_FILES_TOUCHED: ...`
- `CHILD_OVERLAP: ...`
- `CHILD_CHECKS: ...`
- `CHILD_RESULT: ...`

## Important semantics

### `STEP_PREFLIGHT` is not a separate CLI command

Planner action id `STEP_PREFLIGHT` means: rerun read-only preflight/planner.

Use:

```bash
chatgpt_send step read --json
```

### `step auto` is bounded (MVP policy)

`step auto` is intentionally conservative:

- may perform/read only safe whitelisted facade actions
- does **not** perform delegated send (`DELEGATE_SEND_PIPELINE` / `STEP_SEND`)
- returns `step.v1` plus `auto.*` metadata (`requested_max_steps`, `steps_executed`, `actions_executed`, `stop_reason`, `forbidden_action_detected`)

Use `step send --message "..."` for actual delivery.

### Safety > availability

You may see non-zero exits even when the message was actually delivered (for example after timeout + confirm-only/no-resend safety path). In that case:

- do **not** blindly resend
- run `--status --json` and `--explain latest --json`
- re-check chat state read-only

### Preflight freshness gating

Delegated send is blocked if planner preflight is stale (`E_PREFLIGHT_STALE`).

Planner tracks:

- `preflight.fresh`
- `preflight.ttl_sec`
- `preflight.reason_not_fresh`
- `preflight.current.*` and `preflight.token.*`

Fix by running `chatgpt_send step read --json` again (fresh preflight).

### Multi-tab behavior

`status.v1` now exposes structured multi-tab diagnostics:

- `multi_tabs.present`
- `multi_tabs.tab_count`
- `multi_tabs.severity` (`none|warning|block`)
- `multi_tabs.reason`
- `multi_tabs.hint`

If strict routing is already proven (`route_ok`), multi-tabs may be warning-only instead of a hard block.

## Recommended machine policy

- Trust JSON outputs (`status.v1`, `step.v1`, `explain.v1`) over log text.
- Prefer `operator_summary` first, then use `decision.next` / `block` / `preflight` for details.
- Treat `decision.next.action_id` as the primary next step.
- Treat `decision.next.gates` as machine-checkable hints (strings).
- Only use raw logs/evidence for debugging/explanations.

## Evidence and debugging

When a run fails, inspect:

- `state/runs/<RUN_ID>/summary.json`
- `state/runs/<RUN_ID>/manifest.json`
- `state/runs/<RUN_ID>/evidence/`
- `state/protocol.jsonl`
- `state/last_specialist_checkpoint.json`

## Integration anti-patterns (avoid)

- Blind resend after `exit 79/81`
- Parsing only terminal prose output instead of JSON
- Assuming a timeout means the prompt was not delivered
- Ignoring unread reply (`--ack` gate)
- Treating internal shell functions as public API
