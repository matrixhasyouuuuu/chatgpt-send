# ENV Flags (chatgpt-send)

Ключевые переменные окружения и базовые дефолты.

## Routing / safety
- `CHATGPT_SEND_FORCE_CHAT_URL` (default: empty)
- `CHATGPT_SEND_PROTECT_CHAT_URL` (default: empty)
- `CHATGPT_SEND_REQUIRE_CONVO_URL` (default: `1`)
- `CHATGPT_SEND_ALLOW_HOME_SEND` (default: `0`)
- `CHATGPT_SEND_ENFORCE_ACTIVE_PIN_MATCH` (default: `0`)
- `CHATGPT_SEND_STRICT_SINGLE_CHAT` (default: `0`)
- `CHATGPT_SEND_STRICT_SINGLE_CHAT_ACTION` (default: `block`, варианты: `block|close`)
- `CHATGPT_SEND_STRICT_UI_CONTRACT` (default: `0`, при `1` падение на `E_UI_CONTRACT_FAIL`)
- `CHATGPT_SEND_CAPTURE_EVIDENCE` (default: `1`, автоснимок evidence на фатальных E_* таймаутах/фейлах)
- `CHATGPT_SEND_SANITIZE_LOGS` (default: `1`, редактирует чувствительные токены в evidence/log snapshots)
- `state/work_chat_url.txt` — основной источник истины для рабочего `/c/...` чата

## Wait / retry
- `CHATGPT_SEND_AUTO_WAIT_ON_GENERATION` (default: `1`)
- `CHATGPT_SEND_AUTO_WAIT_MAX_SEC` (default: `60`)
- `CHATGPT_SEND_AUTO_WAIT_POLL_MS` (default: `500`)
- `CHATGPT_SEND_REPLY_POLLING` (default: `1`)
- `CHATGPT_SEND_REPLY_POLL_MS` (default: `700`)
- `CHATGPT_SEND_REPLY_MAX_SEC` (default: `90`)
- `CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS` (default: `45000`)
- `CHATGPT_SEND_STALE_STOP_SEC` (default: `8`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_STALE_STOP_POLL_SEC` (default: `0.4`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_ASSISTANT_STABILITY_SEC` (default: `0.9`, guard от раннего capture обрезанного ответа)
- `CHATGPT_SEND_ASSISTANT_PROBE_STABILITY_SEC` (default: `0.4`, стабильность для `--reply-ready-probe`)
- `CHATGPT_SEND_ASSISTANT_STABILITY_POLL_SEC` (default: `0.2`, шаг проверки стабильности)

## Recovery
- `CHATGPT_SEND_CDP_RECOVER_BUDGET` (default: `1`)
- `CHATGPT_SEND_CDP_RECOVER_COOLDOWN_SEC` (default: `2`)
- `CHATGPT_SEND_CDP_RECOVER_LOCK_TIMEOUT_SEC` (default: `30`)
- `CHATGPT_SEND_CDP_RECOVER_LOCK_FILE` (default: `/tmp/chatgpt-send-cdp-recover.lock`)
- `CHATGPT_SEND_RESTART_RECOMMEND_UPTIME_SEC` (default: `14400`, порог для `restart_recommended` в `--doctor --json`)
- `CHATGPT_SEND_ALLOW_BROWSER_RESTART` (default: `0`, разрешает `--graceful-restart-browser`)
- `CHATGPT_SEND_TIMEOUT_BUDGET_WINDOW_SEC` (default: `300`)
- `CHATGPT_SEND_TIMEOUT_BUDGET_MAX` (default: `3`)
- `CHATGPT_SEND_TIMEOUT_BUDGET_ACTION` (default: `restart`, варианты: `restart|fail|off`)
- `CHATGPT_SEND_TIMEOUT_BUDGET_FILE` (default: `$ROOT/state/timeout_budget_events.log`)

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
