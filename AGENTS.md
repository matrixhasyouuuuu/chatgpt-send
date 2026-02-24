# AGENTS.md (chatgpt-send)

This repository exposes a CLI bridge (`bin/chatgpt_send`) for interacting with a visible ChatGPT Web chat through UI automation (CDP), with safety guards and machine-readable JSON outputs.

## Primary integration mode (recommended for AI agents)

Use the UX facade commands instead of calling low-level shell scripts:

- `chatgpt_send --status --json`
- `chatgpt_send --explain latest --json`
- `chatgpt_send step read --json`
- `chatgpt_send step send --message "..." --json`
- `chatgpt_send --ack`

Treat `step read --json` as the planner/preflight command. The planner may return action ids like `STEP_PREFLIGHT`; this maps to running `chatgpt_send step read --json` again.

## Safety model (important)

- Never blind-resend after timeout just because a send command returned non-zero.
- Always check `--status --json` and/or `step read --json` before deciding to send again.
- If there is an unread reply, acknowledge it first: `chatgpt_send --ack`.
- The tool intentionally prefers safety over availability in ambiguous UI states.

Common outcomes:

- `exit 0`: success (or delegated send completed)
- `exit 73`: `step` blocked (follow planner next action)
- `exit 74`: `step` no-op (planner says send not allowed yet)
- `exit 79`: fail-closed environment/confirm issue (read `--explain latest`)
- `exit 81`: safety stop after timeout (`confirm-only/no-resend`)

## JSON-first contract

The stable machine-facing outputs are:

- `status.v1` from `--status --json`
- `explain.v1` from `--explain ... --json`
- `step.v1` from `step read/send/auto --json`

See:

- `docs/JSON_CONTRACTS.md`
- `docs/ERRORS.md`
- `docs/AI_AGENT_INTEGRATION.md`

## Practical loop for another AI agent

1. `chatgpt_send --status --json`
2. `chatgpt_send step read --json`
3. Inspect `decision.next.action_id` and `decision.next.gates`
4. If allowed and message is ready: `chatgpt_send step send --message "..."`
5. If blocked/error: `chatgpt_send --explain latest --json`
6. If unread reply exists: `chatgpt_send --ack`

## Do not rely on

- Raw internal shell functions in `bin/lib/chatgpt_send/*.sh` as an external API
- Transient logs as the only source of truth
- Browser UI timing assumptions without checking fresh `status/step`

Use JSON outputs + evidence files for deterministic behavior.
