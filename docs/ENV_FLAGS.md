# ENV Flags (chatgpt-send)

Ключевые переменные окружения и базовые дефолты.

## Routing / safety
- `CHATGPT_SEND_FORCE_CHAT_URL` (default: empty)
- `CHATGPT_SEND_PROTECT_CHAT_URL` (default: empty)
- `CHATGPT_SEND_REQUIRE_CONVO_URL` (default: `1`)
- `CHATGPT_SEND_ALLOW_HOME_SEND` (default: `0`)
- `CHATGPT_SEND_ENFORCE_ACTIVE_PIN_MATCH` (default: `1`)

## Wait / retry
- `CHATGPT_SEND_AUTO_WAIT_ON_GENERATION` (default: `1`)
- `CHATGPT_SEND_AUTO_WAIT_MAX_SEC` (default: `60`)
- `CHATGPT_SEND_AUTO_WAIT_POLL_MS` (default: `500`)
- `CHATGPT_SEND_REPLY_POLLING` (default: `1`)
- `CHATGPT_SEND_REPLY_POLL_MS` (default: `700`)
- `CHATGPT_SEND_REPLY_MAX_SEC` (default: `90`)

## Recovery
- `CHATGPT_SEND_CDP_RECOVER_BUDGET` (default: `1`)
- `CHATGPT_SEND_CDP_RECOVER_COOLDOWN_SEC` (default: `2`)
- `CHATGPT_SEND_CDP_RECOVER_LOCK_TIMEOUT_SEC` (default: `30`)
- `CHATGPT_SEND_CDP_RECOVER_LOCK_FILE` (default: `/tmp/chatgpt-send-cdp-recover.lock`)

## Runtime paths / profile
- `CHATGPT_SEND_ROOT` (default: repo root)
- `CHATGPT_SEND_PROFILE_DIR` (default: `$ROOT/state/manual-login-profile`)
- `CHATGPT_SEND_LOCK_FILE` (default: empty)
- `CHATGPT_SEND_LOCK_TIMEOUT_SEC` (default: `120`)
- `CHATGPT_SEND_CDP_PORT` (default: `9222`)

## Diagnostics
- `CHATGPT_SEND_STRICT_DOCTOR` (default: `0`)
- `CHATGPT_SEND_PROGRESS` (default: `1`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_ACTIVITY_TIMEOUT_SEC` (default: `45`, в `cdp_chatgpt.py`)
