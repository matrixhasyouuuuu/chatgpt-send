# ENV Flags (chatgpt-send)

Ключевые переменные окружения и базовые дефолты.

## Routing / safety
- `CHATGPT_SEND_TRANSPORT` (default: `cdp`, варианты: `cdp|mock`)
- `CHATGPT_SEND_FORCE_CHAT_URL` (default: empty)
- `CHATGPT_SEND_PROTECT_CHAT_URL` (default: empty)
- `CHATGPT_SEND_REQUIRE_CONVO_URL` (default: `1`)
- `CHATGPT_SEND_ALLOW_HOME_SEND` (default: `0`)
- `CHATGPT_SEND_ENFORCE_ACTIVE_PIN_MATCH` (default: `0`)
- `CHATGPT_SEND_STRICT_SINGLE_CHAT` (default: `1`)
- `CHATGPT_SEND_STRICT_SINGLE_CHAT_ACTION` (default: `block`, варианты: `block|close`)
- `CHATGPT_SEND_FETCH_LAST_N` (default: `6`)
- `CHATGPT_SEND_FETCH_LAST_REQUIRED` (default: `1`, без `FETCH_LAST` отправка блокируется)
- `CHATGPT_SEND_NO_BLIND_RESEND` (default: `1`, запрет повторной отправки без подтверждённого ответа)
- `CHATGPT_SEND_PROTO_ENFORCE_FINGERPRINT` (default: `0`, при `1` блок на `E_CHAT_FINGERPRINT_MISMATCH`)
- `CHATGPT_SEND_PROTO_ENFORCE_POSTSEND_VERIFY` (default: `0`)
- `CHATGPT_SEND_CHAT_SINGLE_FLIGHT` (default: `1`, single-flight lock на chat_url)
- `CHATGPT_SEND_CHAT_LOCK_DIR` (default: `$ROOT/state/locks`)
- `CHATGPT_SEND_CHAT_LOCK_TIMEOUT_SEC` (default: `20`)
- `CHATGPT_SEND_PROTOCOL_LOCK_FILE` (default: `$ROOT/state/protocol.lock`)
- `CHATGPT_SEND_CHECKPOINT_LOCK_FILE` (default: `$ROOT/state/checkpoint.lock`)
- `CHATGPT_SEND_ENFORCE_ITERATION_PREFIX` (default: `1`)
- `CHATGPT_SEND_STRICT_UI_CONTRACT` (default: `0`, при `1` падение на `E_UI_CONTRACT_FAIL`)
- `CHATGPT_SEND_SKIP_STATE_WRITE` (default: `0`, read-only mode for probe/check commands)
- `CHATGPT_SEND_CAPTURE_EVIDENCE` (default: `1`, автоснимок evidence на фатальных E_* таймаутах/фейлах)
- `CHATGPT_SEND_SANITIZE_LOGS` (default: `1`, редактирует чувствительные токены в evidence/log snapshots)
- `state/work_chat_url.txt` — основной источник истины для рабочего `/c/...` чата

## Mock transport (offline)
- `CHATGPT_SEND_TRANSPORT=mock` — включает offline transport без CDP/Chrome
- `CHATGPT_SEND_MOCK_CHAT_URL` (default: empty)
- `CHATGPT_SEND_MOCK_CHAT_URL_FILE` (default: empty; если задан, читается/потребляется по строкам)
- `CHATGPT_SEND_MOCK_REPLY` (default: empty)
- `CHATGPT_SEND_MOCK_REPLY_FILE` (default: empty)
- `CHATGPT_SEND_MOCK_REPLIES_DIR` (default: empty; берётся первый `*.txt`, файл удаляется после чтения)
- `CHATGPT_SEND_MOCK_LAST_PROMPT_FILE` (default: `$ROOT/state/mock_last_prompt.txt`)
- `CHATGPT_SEND_MOCK_SENT_FILE` (default: `$ROOT/state/mock_sent_count.txt`)
- `CHATGPT_SEND_MOCK_PRECHECK_STATUS` (default: empty; если задан, принудительный статус precheck)
- `CHATGPT_SEND_MOCK_PROBE_FAIL_URLS` (default: empty; список URL для принудительного fail в `--probe-chat-url`)
- `CHATGPT_SEND_MOCK_ERROR_CODE` (default: empty; принудительный не-нулевой код для отказа mock операций)

## Wait / retry
- `CHATGPT_SEND_AUTO_WAIT_ON_GENERATION` (default: `1`)
- `CHATGPT_SEND_AUTO_WAIT_MAX_SEC` (default: `60`)
- `CHATGPT_SEND_AUTO_WAIT_POLL_MS` (default: `500`)
- `CHATGPT_SEND_BUSY_POLICY` (default: `auto_stop`, варианты: `auto_stop|wait|fail`)
- `CHATGPT_SEND_BUSY_TIMEOUT_SEC` (default: `20`, таймаут ожидания/stop)
- `CHATGPT_SEND_BUSY_STOP_RETRIES` (default: `2`, попытки авто-нажатия Stop)
- `CHATGPT_SEND_REPLY_POLLING` (default: `1`)
- `CHATGPT_SEND_REPLY_POLL_MS` (default: `700`)
- `CHATGPT_SEND_REPLY_MAX_SEC` (default: `90`)
- `CHATGPT_SEND_REPLY_NO_PROGRESS_MAX_MS` (default: `45000`)
- `CHATGPT_SEND_LATE_REPLY_GRACE_SEC` (default: `30`)
- `CHATGPT_SEND_LATE_REPLY_POLL_MS` (default: `1500`)
- `CHATGPT_SEND_LATE_REPLY_STABLE_TICKS` (default: `2`)
- `CHATGPT_SEND_POSTSEND_VERIFY_FETCH_LAST_N` (default: `4`)
- `CHATGPT_SEND_STALE_STOP_SEC` (default: `8`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_STALE_STOP_POLL_SEC` (default: `0.4`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_ASSISTANT_STABILITY_SEC` (default: `0.9`, guard от раннего capture обрезанного ответа)
- `CHATGPT_SEND_ASSISTANT_PROBE_STABILITY_SEC` (default: `0.4`, стабильность для `--reply-ready-probe`)
- `CHATGPT_SEND_ASSISTANT_STABILITY_POLL_SEC` (default: `0.2`, шаг проверки стабильности)
- `CHATGPT_SEND_CONFIRM_ONLY_RETRY_ATTEMPTS` (default: `2`, read-only confirm-loop attempts после `status4_timeout` перед `exit 81`)
- `CHATGPT_SEND_CONFIRM_ONLY_RETRY_MS` (default: `500`, пауза между read-only confirm-loop попытками; min `100`)

## UX facade / planner (`status`, `explain`, `step`)
- `CHATGPT_SEND_PREFLIGHT_TTL_SEC` (default: `8`, TTL для planner preflight freshness gating перед `DELEGATE_SEND_PIPELINE`)
- `state/status/preflight_token.v1.json` — read-only preflight token (пишется `step read`, используется planner-ом для freshness)

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
- `CHATGPT_SEND_NORM_VERSION` (default: `v1`)

## Diagnostics
- `CHATGPT_SEND_STRICT_DOCTOR` (default: `0`)
- `CHATGPT_SEND_PROGRESS` (default: `1`, в `cdp_chatgpt.py`)
- `CHATGPT_SEND_ACTIVITY_TIMEOUT_SEC` (default: `45`, в `cdp_chatgpt.py`)

## Spawn child auto-monitor
- `SPAWN_AUTO_MONITOR` (default: `1`, включает фоновый монитор child-run в no-wait режиме)
- `SPAWN_AUTO_MONITOR_STDOUT` (default: `0`, зеркалировать monitor-события в stdout)
- `SPAWN_AUTO_MONITOR_POLL_SEC` (default: `2`)
- `SPAWN_AUTO_MONITOR_HEARTBEAT_SEC` (default: `20`, `0` отключает heartbeat)
- `SPAWN_AUTO_MONITOR_TIMEOUT_SEC` (default: `0`, без таймаута)
- `SPAWN_AUTO_MONITOR_SCRIPT` (default: `$ROOT/scripts/child_run_monitor.sh`)

## Fleet registry (child -> pool monitor)
- `CHATGPT_SEND_FLEET_REGISTRY_FILE` (optional: path to append-only `fleet_registry.jsonl`)
- `CHATGPT_SEND_FLEET_AGENT_ID` (optional: coordinator agent index/id for registry row)
- `CHATGPT_SEND_FLEET_ATTEMPT` (optional: retry attempt number for registry row)
- `CHATGPT_SEND_FLEET_ASSIGNED_CHAT_URL` (optional: assigned chat URL for registry row)
- `CHATGPT_SEND_FLEET_REGISTRY_LOCK_TIMEOUT_SEC` (default: `2`, timeout for registry lock before soft-skip with `W_FLEET_REGISTRY_LOCK_TIMEOUT`)

## Agent pool fleet monitor / watchdog / gate
- `POOL_FLEET_MONITOR_SCRIPT` (default: `$ROOT/scripts/child_fleet_monitor.sh`)
- `POOL_FLEET_MONITOR_ENABLED` (default: `1`)
- `POOL_FLEET_MONITOR_POLL_SEC` (default: `2`)
- `POOL_FLEET_MONITOR_HEARTBEAT_SEC` (default: `20`, `0` disables heartbeat file updates)
- `POOL_FLEET_MONITOR_TIMEOUT_SEC` (default: `0`, no timeout)
- `POOL_FLEET_MONITOR_STUCK_AFTER_SEC` (default: `240`)
- `POOL_FLEET_MONITOR_STDOUT` (default: `0`)
- `POOL_FLEET_WATCHDOG_ENABLED` (default: `1`, auto-restart monitor if it dies mid-run)
- `POOL_FLEET_WATCHDOG_COOLDOWN_SEC` (default: `2`)
- `POOL_FLEET_GATE_ENABLED` (default: `1`, strict end-of-run gate)
- `POOL_FLEET_GATE_TIMEOUT_SEC` (default: `20`)
- `POOL_FLEET_GATE_HEARTBEAT_SEC` (default: `0`)
- `POOL_STRICT_CHAT_PROOF` (default: `auto`, варианты: `0|1|auto`; `auto` => strict в live или при `--chat-pool-file`)
- `POOL_FLEET_REGISTRY_LOCK_TIMEOUT_SEC` (default: `2`, propagated to child `spawn_second_agent`)
- `POOL_FLEET_ROSTER_LOCK_TIMEOUT_SEC` (default: `2`, timeout for append to `fleet_roster.jsonl` before soft-skip with `W_FLEET_ROSTER_LOCK_TIMEOUT`)
- `POOL_LOCK_FILE` (default: `/tmp/chatgpt-send-agent-pool.lock`, single-flight lock for whole pool run)
- `POOL_LOCK_TIMEOUT_SEC` (default: `0`, `0` = fail-fast if lock busy)
- `POOL_KILL_GRACE_SEC` (default: `5`, grace period before SIGKILL on abort cleanup)

## Agent pool live follower
- `POOL_FOLLOW` (default: `auto`, варианты: `0|1|auto`; feature toggle follow, `auto` включает follow для multi-agent при включённом monitor)
- `POOL_FOLLOW_MODE` (default: `auto`, варианты: `auto|off|log|cli|both`)
  - `auto`: `both` при TTY, иначе `log`
  - `log`: follow пишет только в log-файл
  - `cli`: follow печатает `PROGRESS ...` в stderr pool-процесса
  - `both`: одновременно в stderr + log через `tee`
  - `off`: отключает follow независимо от `POOL_FOLLOW`
- `POOL_FOLLOW_TICK_MS` (default: `1000`, шаг polling follower-а)
- `POOL_FOLLOW_NO_ANSI` (default: `0`, `1` отключает цвет в `fleet_follow.sh`)
- `POOL_FOLLOW_PID_FILE` (default: `<pool-run-dir>/fleet.follow.pid`)
- `POOL_FOLLOW_LOG` (default: `<pool-run-dir>/fleet.follow.log`)
- `POOL_FLEET_FOLLOW_SCRIPT` (default: `$ROOT/scripts/fleet_follow.sh`)

## Agent pool early gate (mid-run abort/retry)
- `POOL_EARLY_GATE` (default: `auto`, варианты: `0|1|auto`; `auto` включает gate для live или `concurrency>=5`)
- `POOL_EARLY_GATE_TICK_SEC` (default: `5`)
- `POOL_EARLY_GATE_STUCK_FAIL` (default: `1`, fail-fast при any stuck/orphaned)
- `POOL_EARLY_GATE_MAX_STUCK` (default: `0`, порог confirmed stuck)
- `POOL_EARLY_GATE_MAX_ORPHANED` (default: `0`, порог confirmed orphaned)
- `POOL_EARLY_GATE_ACTION` (default: `abort_and_retry`, варианты: `abort|abort_and_retry|abort_no_retry`)
- `POOL_EARLY_GATE_RETRYABLE_CLASSES` (default: `ORPHANED,STUCK`, CSV для selective retry)
- `POOL_EARLY_GATE_CONFIRM_TICKS` (default: `2`, сколько подряд trigger-ticks нужно для срабатывания early-abort)
- `POOL_EARLY_GATE_CONFIRM_MODE` (default: `consecutive`, текущий режим подтверждения trigger-тиков)

## Agent pool retention / GC
- `POOL_RUNS_ROOT` (default: `$ROOT/state/runs`, root for pool run directories)
- `POOL_GC` (default: `auto`, варианты: `0|1|auto`)
- `POOL_GC_KEEP_LAST` (default: `20`)
- `POOL_GC_KEEP_HOURS` (default: `72`)
- `POOL_GC_MAX_TOTAL_MB` (default: `2048`)
- `POOL_GC_FREE_WARN_PCT` (default: `10`, при `POOL_GC=auto` GC запускается если free_pct <= warn)
- `POOL_GC_SCRIPT` (default: `$ROOT/scripts/fleet_gc.sh`)
- `FLEET_GC_ACTIVE_HEARTBEAT_SEC` (default: `120`, safeguard для активного run по свежему `fleet.heartbeat`)

## Agent pool report
- `POOL_WRITE_REPORT` (default: `1`)
- `POOL_REPORT_SCRIPT` (default: `$ROOT/scripts/pool_report.sh`)
- `POOL_REPORT_MD` (default: `<pool-run-dir>/pool_report.md`)
- `POOL_REPORT_JSON` (default: `<pool-run-dir>/pool_report.json`)
- `POOL_REPORT_MAX_LAST_LINES` (default: `80`)
- `POOL_REPORT_INCLUDE_LOGS` (default: `0`)

## Live preflight / demo
- `LIVE_CONCURRENCY` (default: `2`, expected live parallel size)
- `LIVE_CHAT_POOL_FILE` (optional: chat pool file for scaled live runs)
- `LIVE_CHAT_POOL_PRECHECK` (default: `auto`, варианты: `0|1|auto`; `auto` включает per-chat precheck для scale `LIVE_CONCURRENCY>=5`)
- `LIVE_DEMO_TASKS_FILE` (default: `$ROOT/scripts/demo_tasks_10.txt`)
- `LIVE_ITERATIONS` (default: `1`, per-agent iterations in live pool demo mode)
- `LIVE_PROJECT_PATH` (default: repo root, project passed into `agent_pool_run.sh`)
- `ALLOW_WORK_CHAT_FOR_LIVE` (default: `0`, allow fallback to work chat when e2e chat missing)

## Fleet monitor disk guard
- `FLEET_DISK_PATH` (default: `<pool-run-dir>`)
- `FLEET_DISK_FREE_WARN_PCT` (default: `10`)
- `FLEET_DISK_FREE_FAIL_PCT` (default: `5`)
