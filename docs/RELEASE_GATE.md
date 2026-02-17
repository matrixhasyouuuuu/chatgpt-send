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
bash test/test_auto_wait_on_generation.sh
bash test/test_reply_wait_polling.sh
bash test/test_soft_reset_runtime_eval_timeout.sh
bash test/test_spawn_second_agent.sh
bash test/test_cdp_chatgpt_wait.sh
bash test/test_cdp_chatgpt_stale_guard.sh
bash test/test_home_probe_no_active_switch.sh state/golden/T_e2e_home_probe_no_active_switch.log
```

## Soak / Chaos
Целевой soak-прогон: 200 итераций рабочего цикла (single-agent) + хаос-проверки.

Рекомендуемые хаос-сценарии:
- kill Chrome mid-run,
- transient CDP DOWN,
- wrong-tab/multi-tab contention.

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
MAX_CHAT_MISROUTE_TOTAL=0
MAX_AUTO_WAIT_TIMEOUT_TOTAL=0
MAX_E_REPLY_WAIT_TIMEOUT=0
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
MIN_DOCTOR_INVARIANTS_OK=1
```

### THRESHOLDS_SOAK (machine-parseable)
```text
SOAK_ITERS=200
MAX_SOAK_FAILS=0
MAX_E_ROUTE_MISMATCH=0
MAX_E_SEND_WITHOUT_PRECHECK=0
MAX_CHAT_MISROUTE_TOTAL=0
MAX_AUTO_WAIT_TIMEOUT_TOTAL=0
MAX_E_REPLY_WAIT_TIMEOUT=0
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
MIN_DOCTOR_INVARIANTS_OK=1
```

## Логи и маркеры, которые должны быть в системе
- `E_ROUTE_MISMATCH`
- `E_MESSAGE_NOT_ECHOED`
- `E_ACTIVITY_TIMEOUT`
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
