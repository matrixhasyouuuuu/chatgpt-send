# Release Gate (Prod-Ready Criteria)

Дата: 2026-02-17
Проект: `chatgpt-send`

## Цель
Формальный `GO/NO-GO` перед production:
- предсказуемая маршрутизация в нужный чат,
- bounded recovery без "тихих успехов",
- наблюдаемость по маркерам ошибок и восстановления.

## Базовый прогон
Минимум перед gate:

```bash
bash test/test_cli.sh
bash test/test_cleanup_idempotent.sh
bash test/test_doctor_invariants.sh
bash test/test_run_manifest_summary.sh
bash test/test_restart_not_allowed_by_default.sh
bash test/test_graceful_restart_preserves_work_chat.sh
bash test/test_timeout_budget_fails_when_restart_not_allowed.sh
bash test/test_timeout_budget_triggers_restart_in_soak.sh
bash test/test_prompt_lint.sh
bash test/test_ui_contract_probe.sh
bash test/test_evidence_bundle_on_timeout.sh
bash test/test_evidence_sanitizer.sh
bash test/test_ack_blocks_send.sh
bash test/test_ack_allows_next_send.sh
bash test/test_duplicate_prompt_blocked.sh
bash test/test_set_chatgpt_url_protect_mismatch.sh
bash test/test_strict_single_chat_block.sh
bash test/test_work_chat_url_priority.sh
bash test/test_auto_wait_on_generation.sh
bash test/test_reply_wait_polling.sh
bash test/test_soft_reset_runtime_eval_timeout.sh
bash test/test_init_specialist_home_transition_reply_wait.sh
bash test/test_init_specialist_ignores_stale_work_chat.sh
bash test/test_spawn_second_agent_e2e_mock_transport.sh
bash test/test_multi_agent_parallel_e2e_mock_transport.sh
bash test/test_spawn_second_agent.sh
bash test/test_spawn_second_agent_auto_monitor.sh
bash test/test_spawn_second_agent_registry.sh
bash test/test_spawn_second_agent_registry_lock_timeout.sh
bash test/test_child_fleet_monitor.sh
bash test/test_child_fleet_monitor_offline.sh
bash test/test_child_fleet_monitor_heartbeat.sh
bash test/test_child_fleet_monitor_disk_guard.sh
bash test/test_child_fleet_monitor_roster_discovery.sh
bash test/test_child_fleet_monitor_chat_proof_ok.sh
bash test/test_child_fleet_monitor_chat_proof_mismatch.sh
bash test/test_chat_pool_manager_check.sh
bash test/test_chat_pool_manage_validate.sh
bash test/test_chat_pool_manage_extract_from_state.sh
bash test/test_chat_pool_precheck_mock_all_ok.sh
bash test/test_chat_pool_precheck_mock_one_fail.sh
bash test/test_live_preflight_requires_precheck_for_scale.sh
bash test/test_fleet_follow_once_renders_counts.sh
bash test/test_fleet_follow_waits_for_summary.sh
bash test/test_agent_pool_follow_streams_progress_to_cli.sh
bash test/test_agent_pool_early_gate_triggers_on_stuck.sh
bash test/test_agent_pool_early_gate_no_flap_on_transient_unknown.sh
bash test/test_agent_pool_early_gate_confirm_ticks_prevents_single_tick_abort.sh
bash test/test_agent_pool_early_gate_confirm_ticks_triggers_on_two_ticks.sh
bash test/test_agent_pool_early_abort_then_retry_retryables.sh
bash test/test_agent_pool_mock_5_agents.sh
bash test/test_agent_pool_follow_mock_5_agents.sh
bash test/test_agent_pool_auto_monitor_watchdog.sh
bash test/test_agent_pool_single_flight_lock.sh
bash test/test_agent_pool_interrupt_cleanup.sh
bash test/test_fleet_gc_prunes_old_runs.sh
bash test/test_agent_pool_gc_auto_forced.sh
bash test/test_pool_report_md_from_mock_pool.sh
bash test/test_pool_report_includes_failures_section.sh
bash test/test_pool_report_includes_early_abort_section.sh
bash test/test_agent_pool_roster_survives_registry_skip.sh
bash test/test_agent_pool_fleet_gate_incomplete_roster.sh
bash test/test_agent_pool_gate_chat_mismatch_fails_strict.sh
bash test/test_cdp_chatgpt_wait.sh
bash test/test_assistant_stability_guard.sh
bash test/test_echo_miss_recover_no_resend.sh
bash test/test_echo_miss_recover_soft_reset_probe_reuse.sh
bash test/test_resend_idempotency_skips_when_reply_tracked.sh
bash test/test_cdp_chatgpt_stale_guard.sh
bash test/test_home_probe_no_active_switch.sh state/golden/T_e2e_home_probe_no_active_switch.log
```

## Soak / Chaos
Целевой soak-прогон: 200 итераций рабочего цикла (single-agent) + хаос-проверки.

Рекомендуемые хаос-сценарии:
- kill Chrome mid-run,
- transient CDP DOWN,
- wrong-tab/multi-tab contention.

## LIVE CDP E2E (opt-in)
Эти проверки запускаются только вручную и не входят в обязательный базовый прогон.

```bash
export RUN_LIVE_CDP_E2E=1

# Рекомендуется отдельный e2e чат:
# echo 'https://chatgpt.com/c/<e2e_chat_id>' > state/chatgpt_url_e2e.txt
# (fallback в рабочий чат только явно)
# export ALLOW_WORK_CHAT_FOR_LIVE=1

bash test/test_spawn_second_agent_e2e_cdp_smoke.sh
bash test/test_multi_agent_parallel_e2e_cdp_shared_slots.sh

# pool smoke (2 live child), требует state/chat_pool_e2e_2.txt
bash test/test_agent_pool_live_2_agents.sh
bash test/test_chat_pool_manager_probe_live_2.sh

# собрать и проверить pool из state/chats.json (пример)
bash scripts/chat_pool_manage.sh extract --out state/chat_pool_e2e_10.txt --count 10
bash scripts/chat_pool_manage.sh validate --chat-pool-file state/chat_pool_e2e_10.txt --min 10
bash scripts/live_chat_pool_precheck.sh --chat-pool-file state/chat_pool_e2e_10.txt --concurrency 10

# единый демонстрационный прогон preflight + bootstrap-once + smoke + parallel
bash scripts/run_live_multi_agent_demo.sh
```

Если нет готового окружения (CDP down, нет e2e chat URL/pool в state, требуется логин/Cloudflare), тесты должны завершаться через `SKIP_*`, а не ложным FAIL.

`scripts/live_preflight.sh` теперь дополнительно печатает:
- `OK_E2E_CHAT_URL`, `E2E_CHAT_URL`,
- `OK_CHAT_POOL`, `CHAT_POOL_COUNT`,
- `OK_CHAT_POOL_PRECHECK`, `CHAT_POOL_PRECHECK_STATUS`, `CHAT_POOL_PRECHECK_SUMMARY_JSON`,
- `LIVE_CHAT_SOURCE`, `LIVE_CHAT_URL`,
- и завершает `exit 14`, если не найден ни e2e/work/pool chat.
- и завершает `exit 15`, если `LIVE_CONCURRENCY>=5` и не задан `LIVE_CHAT_POOL_FILE`.
- и завершает `exit 16`, если per-chat precheck пула не прошёл (`E_CHAT_POOL_PRECHECK_FAILED`).

`scripts/live_specialist_bootstrap_once.sh` отправляет bootstrap в live чат не чаще TTL (по умолчанию 24h) и пишет маркеры:
- `BOOTSTRAP_ONCE send ...`
- `BOOTSTRAP_ONCE skip reason=cached ...`
- `BOOTSTRAP_ONCE done ...`

## Пороговые критерии (thresholds)
`GO`, если одновременно:

1. `E_ROUTE_MISMATCH == 0` в рабочих прогонах.
2. `E_MESSAGE_NOT_ECHOED <= 0.5%` (с 1 controlled retry).
3. `E_CDP_UNREACHABLE.recover_once <= 1` на 100 итераций.
4. Нет "тихих успехов":
   - при исчерпанном recover budget есть явный fail-маркер,
   - нет скрытого переключения active/loop контекста.
5. Для browser-required child:
   - есть `CHILD_BROWSER_USED: yes`,
   - `EVIDENCE` указывает на ожидаемый `/c/...` чат.

### THRESHOLDS_PROD (machine-parseable)
```text
MAX_E_ROUTE_MISMATCH=0
MAX_E_SLOT_ACQUIRE_TIMEOUT=0
MAX_E_CDP_RECOVER_BUDGET_EXCEEDED=0
MAX_E_SEND_WITHOUT_PRECHECK=0
MAX_E_PROTECT_CHAT_MISMATCH=0
MAX_E_MULTIPLE_CHAT_TABS_BLOCKED=0
MAX_PROMPT_LINT_FAILS=0
MAX_E_UI_CONTRACT_FAIL=0
MAX_CHAT_MISROUTE_TOTAL=0
MAX_AUTO_WAIT_TIMEOUT_TOTAL=0
MAX_E_REPLY_WAIT_TIMEOUT=0
MAX_E_REPLY_UNACKED_BLOCK_SEND=0
MAX_E_DUPLICATE_PROMPT_BLOCKED=0
MAX_E_PROD_CHAT_PROTECTED=0
MAX_E_SOFT_RESET_FAILED_TOTAL=0
MAX_E_CDP_PORT_IN_USE=0
MAX_SLOT_RELEASE_FORCED_TOTAL=0
MAX_E_FLOW_ORDER_VIOLATION=0
MAX_E_CDP_UNREACHABLE_RECOVER_PER_100=1
MAX_P95_LOCK_WAIT_MS=500
MAX_P95_LOCK_HELD_MS=5000
MAX_P95_PRECHECK_MS=3000
MAX_P95_SEND_MS=20000
MAX_P95_WAIT_REPLY_MS=60000
MAX_P95_TOTAL_MS=120000
MIN_ITER_STATUS_LINES_PER_CHILD=2
MIN_PROFILE_DIR_USED_TOTAL=1
MIN_ACK_WRITE_TOTAL=1
MIN_DOCTOR_INVARIANTS_OK=1
```

### THRESHOLDS_SOAK (machine-parseable)
```text
SOAK_ITERS=200
MAX_SOAK_FAILS=0
MAX_E_ROUTE_MISMATCH=0
MAX_E_SEND_WITHOUT_PRECHECK=0
MAX_E_PROTECT_CHAT_MISMATCH=0
MAX_E_MULTIPLE_CHAT_TABS_BLOCKED=0
MAX_PROMPT_LINT_FAILS=0
MAX_E_UI_CONTRACT_FAIL=0
MAX_CHAT_MISROUTE_TOTAL=0
MAX_AUTO_WAIT_TIMEOUT_TOTAL=0
MAX_E_REPLY_WAIT_TIMEOUT=0
MAX_E_REPLY_UNACKED_BLOCK_SEND=0
MAX_E_DUPLICATE_PROMPT_BLOCKED=0
MAX_E_PROD_CHAT_PROTECTED=0
MAX_E_SOFT_RESET_FAILED_TOTAL=0
MAX_E_CDP_PORT_IN_USE=0
MAX_SLOT_RELEASE_FORCED_TOTAL=0
MAX_E_FLOW_ORDER_VIOLATION=0
MAX_E_CDP_RECOVER_BUDGET_EXCEEDED=0
MAX_E_CDP_UNREACHABLE_PER_200=2
MAX_P95_LOCK_WAIT_MS=500
MAX_P95_LOCK_HELD_MS=8000
MAX_P95_PRECHECK_MS=5000
MAX_P95_SEND_MS=30000
MAX_P95_WAIT_REPLY_MS=90000
MAX_P95_TOTAL_MS=180000
MAX_TESTS_SKIPPED=0
MIN_PROFILE_DIR_USED_TOTAL=1
MIN_ACK_WRITE_TOTAL=1
MIN_DOCTOR_INVARIANTS_OK=1
```

## Логи и маркеры, которые должны быть в системе
- `E_ROUTE_MISMATCH`
- `E_PROTECT_CHAT_MISMATCH`
- `E_MULTIPLE_CHAT_TABS_BLOCKED`
- `E_MESSAGE_NOT_ECHOED`
- `E_ACTIVITY_TIMEOUT`
- `E_REPLY_UNACKED_BLOCK_SEND`
- `E_DUPLICATE_PROMPT_BLOCKED`
- `ACK_WRITE`
- `PROMPT_LINT_FAILS`
- `E_UI_CONTRACT_FAIL`
- `EVIDENCE_CAPTURED`
- `E_TAB_NOT_FOUND.retry`
- `E_CDP_UNREACHABLE.recover_once`
- `E_CDP_RECOVER_LOCK_TIMEOUT`
- `E_CDP_RECOVER_BUDGET_EXCEEDED`
- `[P4] cdp_recover single_flight ...`
- `[P4] cdp_recover used=X/Y ...`

## Rollback-правило
`NO-GO`, если:
- thresholds не соблюдены,
- есть нестабильный или неинтерпретируемый fallback,
- есть риск маршрутизации в неверный чат.

Rollback:
- откат последних reliability-правок до стабильного baseline,
- повторный прогон базовых тестов + минимальный smoke,
- повторный заход в gate только после исправления причины.
