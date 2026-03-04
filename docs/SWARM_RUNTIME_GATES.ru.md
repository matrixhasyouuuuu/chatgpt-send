# Swarm Runtime Gates (Координатору)

Этот документ собирает в одном месте правила/гейты, которые уже зашиты в коде `chatgpt-send` и реально ограничивают запуск/прохождение child-агентов.

Важно:
- Это **runtime-gates** (внешний контроль кодом), а не “память агента”.
- Агент может не знать эти проверки.
- Координатор узнает о проблеме по `exit code` + тексту ошибки launcher'а + `CHILD_RESULT_JSON`/логам.

Связанные документы:
- Философия роя: `chatgpt-send/AGENTS.md` (секция `## Роевая задача (Swarm task)`)
- Концепт улья/сот: `chatgpt-send/docs/SWARM_HIVE_CONCEPT.ru.md`

## Что уже реально мешает нарушать (в коде)

1. Swarm-context preflight (неполный рой режется до запуска)
- Где: `chatgpt-send/bin/spawn_second_agent`
- Ключевые места: `:51`, `:246`, `:270`
- Что делает:
  - проверяет `--agent-id`, `--agent-name`, `--team-goal`, `--peer`
  - при strict (`--swarm-context-required`) требует полный набор
  - при partial swarm-context тоже блокирует запуск
- Что видит координатор:
  - ошибка в `stderr`
  - список недостающих полей
  - `exit 2`
- Что НЕ происходит:
  - child-агент не стартует вообще

2. Timeout и wait (завис — обрывается)
- Где: `chatgpt-send/bin/spawn_second_agent`
- Ключевые места: `:35`, `:36`, `:1192`
- Что делает:
  - в `--wait` режиме launcher ждет завершение child до `--timeout-sec`
  - если таймаут превышен -> ошибка и завершение launcher
- Что видит координатор:
  - `Error: wait timeout (...) exceeded.`
  - non-zero exit

3. Browser policy (required/disabled) с проверкой по логам/маркеру
- Где: `chatgpt-send/bin/spawn_second_agent`
- Ключевые места: `:116`, `:889`, `:902`
- Что делает:
  - после выполнения child проверяет маркер `CHILD_BROWSER_USED: ...`
  - проверяет evidence (chat URL), факт вызова `chatgpt_send`, соответствие policy
  - при нарушении выставляет `E_CHILD_BROWSER_*` и fail
- Что видит координатор:
  - статус в `CHILD_RESULT_JSON`
  - код возврата (например 41..45)
  - подробности в `LOG_FILE`

4. CDP slot / lock (не получил слот — fail)
- Где: `chatgpt-send/bin/spawn_second_agent`
- Ключевое место: `:687`
- Что делает:
  - child wrapper ждет слот браузера (`CDP slot`)
  - если не дождался -> `E_SLOT_ACQUIRE_TIMEOUT`
- Что видит координатор:
  - fail в child
  - подробности в `LOG_FILE` / `STATUS_FILE`

5. Внутренний порядок фаз wrapper (`read -> execute -> report`)
- Где: `chatgpt-send/bin/spawn_second_agent`
- Ключевое место: `:991`
- Что делает:
  - wrapper пишет свои служебные `FLOW_OK`
  - проверяет порядок служебных фаз
  - при нарушении выставляет `E_FLOW_ORDER_VIOLATION`
- Что важно:
  - это контроль работы wrapper'а, не “мышления агента”

6. `agent_pool_run` всегда запускает child в `--wait` + timeout и собирает `CHILD_RESULT_JSON`
- Где: `chatgpt-send/scripts/agent_pool_run.sh`
- Ключевые места: `:1549`, `:1550`, `:1573`
- Что делает:
  - запускает child с ожиданием завершения
  - читает `CHILD_RESULT_JSON`
  - пишет в `summary.jsonl`, fleet registry/summary
- Что это дает:
  - координатор (или pool-оркестратор) принимает решение по структурированному результату, а не только по тексту

## Что это НЕ решает (важно)

Эти гейты не гарантируют, что агент:
- выполнил все смысловые шаги задачи,
- не перепрыгнул этап,
- не “забыл” часть проверки.

Они гарантируют в основном:
- корректность запуска,
- базовую дисциплину среды,
- некоторые policy-checks,
- сбор результата в структуру.

Для контроля шагов задачи нужны отдельные `step-gates`:
- карта шагов (workflow rules),
- validator шага,
- запрет перехода к следующему шагу без `validator=OK`.

## Как координатор понимает, что запуск не прошел

Зависит от типа ошибки:

1. Ошибка до запуска child (например preflight)
- координатор видит:
  - `stderr` launcher'а
  - `exit != 0` (обычно `2`)
- child не стартует

2. Ошибка после запуска child (runtime/policy)
- координатор видит:
  - `CHILD_STATUS`
  - `CHILD_RESULT_JSON`
  - `LOG_FILE`
  - `LAST_FILE`
  - (в pool) `summary.jsonl`, `fleet.summary.json`

## Зачем этот документ

Чтобы не искать правила по всему коду вручную.

Этот файл — обзор “что уже зашито”.
Следующий шаг (если будете внедрять step-gates) — завести отдельные:
- `workflow_rules.*`
- `rule_errors.*`

и уже их делать первичным источником правил шагов.
