# Error Guide for AI Agents (`E_*`)

This is a practical guide for integrations. The source of truth is `ux/error_registry.py` + `chatgpt_send --explain ... --json`.

## Recommended handling pattern

After any non-zero send/run or blocked planner state:

1. `chatgpt_send --status --json`
2. `chatgpt_send --explain latest --json`
3. Follow `decision.next.action_id` / `next_actions`

## Common error codes (current important set)

## `E_ACK_REQUIRED` / `E_REPLY_UNACKED_BLOCK_SEND`

Meaning:

- unread Specialist reply is pending; send is blocked until acknowledged

Do:

- read reply
- `chatgpt_send --ack`
- rebuild plan with `step read --json`

## `E_PREFLIGHT_STALE`

Meaning:

- planner preflight is stale (TTL expired / target mismatch / fingerprint mismatch / missing token)

Do:

- `chatgpt_send step read --json` (refresh preflight)
- retry `step send --message ...` only if planner allows delegated send

## `E_SEND_RETRY_VETO_INTRA_RUN`

Meaning:

- timeout recovery branch blocked resend inside the same run to avoid duplicate prompt

Do:

- `chatgpt_send --status --json`
- `chatgpt_send --explain latest --json`
- read-only re-check before any resend decision

## `E_PROMPT_NOT_CONFIRMED_NO_RESEND`

Meaning:

- after timeout, prompt delivery could not be confirmed automatically; system stopped without resending (safety stop)

Do:

- re-check chat state read-only (`status`, `step read`, fetch-last path)
- if prompt/reply appeared, continue without resend and `--ack`
- only resend after stable confirmation that prompt was not delivered

## `E_CONFIRM_FETCH_LAST_FAILED`

Meaning:

- confirm-only read (`fetch_last`) failed; fail-closed stop to avoid duplicate

Do:

- inspect `--status --json`
- inspect `--explain latest --json`
- stabilize browser/CDP, then re-check read-only before retry

## `E_CDP_TIMEOUT_RETRY`

Meaning:

- timeout recovery path engaged (status4 timeout), usually followed by confirm-only/no-resend logic

Do:

- inspect `--explain latest --json`
- follow planner/status hints; do not blind resend

## `E_CDP_DOWN` / `E_CDP_UNREACHABLE`

Meaning:

- browser/CDP automation endpoint unavailable

Do:

- `chatgpt_send --open-browser` or `--graceful-restart-browser`
- then re-run `--status --json`

## `E_ROUTE_MISMATCH`

Meaning:

- active tab / routing does not match target work chat (strict routing safety)

Do:

- activate correct chat tab / sync chat URL
- rerun `--status --json` and `step read --json`

## `E_SOFT_RESET_FAILED`

Meaning:

- UI/CDP soft reset failed during recovery

Do:

- inspect evidence via `--explain latest --json`
- consider `--graceful-restart-browser`
- then read-only validation

## Notes

- `chatgpt_send --explain E_CODE --json` can explain a code directly.
- New exact registry entries may be added over time; use tolerant parsers.
- Use `block_reason` + `next_actions` rather than custom heuristics whenever possible.
