# Deep Project Analysis: chatgpt-send

Дата анализа: 2026-02-16
Проект: `/home/matrix/projects/chatgpt-send`

## 1) Объем и методика

Анализ выполнен по направлениям: `db-analyzer`, `tools-inspector`, `logs-hunter`, `crm-explorer`, `webhook-analyzer`.

Использованные команды поиска (по репозиторию):
- `rg -n "sqlite|postgres|mysql|mongo|redis|sqlalchemy|psycopg|pg8000|aiosqlite|CREATE TABLE|ALTER TABLE|schema|migrate|migration|history|conversation|messages|transcript|audit" .`
- `rg -n "tool|agent|subagent|plugin|instrument|retry|timeout|backoff|circuit|fallback|error|exception" .`
- `rg -n "log|logger|logging|trace|audit|\.log$|logs/|logfile|log_path" .`
- `rg -n "bitrix|amocrm|crm|lead|deal|pipeline|webhook|oauth|token|refresh_token|client_id|client_secret|callback|receiver|signature|secret" .`
- `rg -n "fastapi|flask|django|express|router|route|endpoint|http.server|requests|urllib|curl" .`

## 2) Карта проекта

Состав файлов (по `rg --files`):
- `README.md`
- `requirements.txt`
- `bin/chatgpt_send` (главный CLI)
- `bin/cdp_chatgpt.py` (CDP automation)
- `bin/chrome_no_sandbox` (launcher для Chrome/Chromium)
- `bin/doctor` (обертка диагностики)
- `test/test_cli.sh` (shell smoke/regression тест)
- `docs/WHY.md`
- `docs/specialist_bootstrap.txt`
- `docs/specialist_bootstrap.ru.txt`
- `skills/chatgpt-web-handoff/SKILL.md`

Главная идея проекта:
- CLI-мост между терминалом и ChatGPT Web через CDP, без API-ключей (`README.md:3`, `README.md:5`, `README.md:237`).
- Роли: Codex выполняет действия в репозитории, Specialist держит длинный контекст (`README.md:9`, `README.md:10`, `README.md:11`).

Ключевые зависимости:
- Python-пакет: `websocket-client` (`requirements.txt:1`).
- Внешние утилиты: `curl`, Chrome/Chromium, опционально `wmctrl` (`README.md:91`, `README.md:93`, `README.md:95`).

## 3) Архитектура и основные потоки

Точка входа и состояние:
- Основной скрипт: `bin/chatgpt_send` (`bin/chatgpt_send:1`).
- Корень состояния вычисляется из пути скрипта с учетом symlink (`bin/chatgpt_send:11`, `bin/chatgpt_send:14`, `bin/chatgpt_send:21`, `bin/chatgpt_send:22`).
- Локальное состояние хранится в `ROOT/state` (`bin/chatgpt_send:23`):
  - профиль браузера: `state/manual-login-profile` (`bin/chatgpt_send:33`)
  - pinned URL: `state/chatgpt_url.txt` (`bin/chatgpt_send:36`)
  - сессии: `state/chats.json`, `state/sessions.md` (`bin/chatgpt_send:37`, `bin/chatgpt_send:38`)

Открытие браузера:
- Поднимается Chrome с CDP на `127.0.0.1:<port>` (`bin/chatgpt_send:691`, `bin/chatgpt_send:692`).
- Добавляется `--remote-allow-origins` для стабильного websocket-подключения CDP (`bin/chatgpt_send:693`).
- При сбое выполняется попытка убить stale PID и перезапустить (`bin/chatgpt_send:712`, `bin/chatgpt_send:717`, `bin/chatgpt_send:721`).
- Логи запуска Chrome пишутся во временный файл `/tmp/chatgpt_send_chrome_<port>.log` (`bin/chatgpt_send:685`, `bin/chatgpt_send:747`).

CDP-автоматизация отправки:
- Bash-скрипт вызывает Python `bin/cdp_chatgpt.py` (`bin/chatgpt_send:1369`).
- Python читает вкладки из `http://127.0.0.1:<port>/json/list` (`bin/cdp_chatgpt.py:321`) и подключается по `webSocketDebuggerUrl` (`bin/cdp_chatgpt.py:327`).
- Запросы в DOM делаются через `Runtime.evaluate` с retry на transient ошибки (`bin/cdp_chatgpt.py:94`, `bin/cdp_chatgpt.py:98`, `bin/cdp_chatgpt.py:119`).
- Ожидание готовности composer/idle (`bin/cdp_chatgpt.py:272`, `bin/cdp_chatgpt.py:293`), отправка prompt (`bin/cdp_chatgpt.py:175`), ожидание завершения генерации (`bin/cdp_chatgpt.py:230`, `bin/cdp_chatgpt.py:266`).

Сессии и loop:
- CRUD по сессиям в JSON через встроенные Python one-liner блоки (`bin/chatgpt_send:176`, `bin/chatgpt_send:225`, `bin/chatgpt_send:264`).
- Loop-счетчик (`loop_max`, `loop_done`) на активной сессии (`bin/chatgpt_send:363`, `bin/chatgpt_send:389`, `bin/chatgpt_send:413`, `bin/chatgpt_send:448`).
- Команды loop вынесены в CLI-флаги (`bin/chatgpt_send:107`, `bin/chatgpt_send:108`, `bin/chatgpt_send:109`, `bin/chatgpt_send:110`).

## 4) db-analyzer (БД, хранение, история)

Итог: классическая СУБД не используется; используется файловое хранилище состояния.

Что найдено:
- Сессии и метаданные хранятся в JSON/Markdown (`bin/chatgpt_send:37`, `bin/chatgpt_send:38`, `bin/chatgpt_send:189`).
- Чтение/запись базы сессий реализовано через `chats_db_read/chats_db_write` (`bin/chatgpt_send:176`, `bin/chatgpt_send:184`).
- Формирование `state/sessions.md` из JSON (`bin/chatgpt_send:189`, `bin/chatgpt_send:222`).
- README явно документирует хранение в `state/chats.json` и `state/sessions.md` (`README.md:160`, `README.md:162`, `README.md:163`).

Чего не найдено:
- `sqlite/postgres/mysql/mongo/redis` подключения и ORM не обнаружены (поиск `rg` выше без релевантных совпадений в коде).
- SQL DDL/миграции (`CREATE TABLE`, `ALTER TABLE`, migration scripts) не обнаружены.

Вывод по data-flow:
- Источник данных: открытые вкладки CDP + локальные файлы `state/*`.
- Целевая запись: `state/chatgpt_url.txt`, `state/chats.json`, `state/sessions.md`.
- Внешней БД и миграционного слоя нет.

## 5) tools-inspector (Инструменты, агенты, отказоустойчивость)

Инструменты и компоненты:
- `bin/chatgpt_send` — оркестрация CLI/состояния/CDP (`bin/chatgpt_send:62`, `bin/chatgpt_send:973`).
- `bin/cdp_chatgpt.py` — низкоуровневое управление вкладкой ChatGPT через CDP websocket (`bin/cdp_chatgpt.py:62`, `bin/cdp_chatgpt.py:74`).
- `bin/chrome_no_sandbox` — запуск Chrome/Chromium в ограниченных средах (`bin/chrome_no_sandbox:27`, `bin/chrome_no_sandbox:35`).
- `bin/doctor` — быстрая диагностика (`bin/doctor:7`, `bin/doctor:9`).

Паттерны обработки ошибок и retry:
- Таймауты:
  - общий `--timeout`, авто-значение 900s (`bin/chatgpt_send:113`, `bin/chatgpt_send:119`, `bin/chatgpt_send:123`)
  - timeout на CDP eval/call в Python (`bin/cdp_chatgpt.py:74`, `bin/cdp_chatgpt.py:82`, `bin/cdp_chatgpt.py:318`).
- Retry transient ошибок UI/CDP:
  - `Runtime.evaluate` retry до 3 раз на разрушенный execution context (`bin/cdp_chatgpt.py:95`, `bin/cdp_chatgpt.py:98`, `bin/cdp_chatgpt.py:119`).
  - retry отправки prompt до 20 попыток при `send button not found` / `prompt editor not found` (`bin/cdp_chatgpt.py:365`, `bin/cdp_chatgpt.py:370`).
- Recovery при CDP websocket reject:
  - возврат кода 6 + перезапуск Chrome в Bash (`bin/cdp_chatgpt.py:334`, `bin/cdp_chatgpt.py:341`, `bin/chatgpt_send:1381`, `bin/chatgpt_send:1392`).
- Безопасные helper-вызовы без падения команды:
  - `wmctrl` best-effort и `|| true` (`bin/chatgpt_send:521`, `bin/chatgpt_send:526`, `bin/chatgpt_send:668`).

Тесты:
- `test/test_cli.sh` покрывает базовые сценарии:
  - пустой список сессий (`test/test_cli.sh:16`)
  - reject невалидного `/c/` URL (`test/test_cli.sh:22`, `test/test_cli.sh:24`)
  - сохранение/переключение сессии (`test/test_cli.sh:43`, `test/test_cli.sh:45`)
  - loop init/inc/clear (`test/test_cli.sh:54`, `test/test_cli.sh:57`, `test/test_cli.sh:60`).
- Интеграционных тестов с реальным Chrome/CDP и реальным chatgpt.com в репозитории нет.

## 6) logs-hunter (Логи, трассировки, история)

Что найдено:
- Временный лог запуска Chrome:
  - путь `/tmp/chatgpt_send_chrome_<CDP_PORT>.log` (`bin/chatgpt_send:685`)
  - tail при ошибке запуска (`bin/chatgpt_send:746`, `bin/chatgpt_send:747`).
- История/состояние сессий (не log в классическом виде, но исторические данные):
  - `state/chats.json`, `state/sessions.md` (`bin/chatgpt_send:37`, `bin/chatgpt_send:38`, `README.md:162`, `README.md:163`).
- Репозиторий исключает `state/` и `*.log` из git (`.gitignore:2`, `.gitignore:9`).

Формат и ротация:
- Ротации логов нет; используется single temp log-файл на порт с удалением перед запуском (`bin/chatgpt_send:687`).
- `sessions.md` перегенерируется из JSON (`bin/chatgpt_send:189`, `bin/chatgpt_send:222`).

Риски утечки данных:
- `state/manual-login-profile` содержит cookies/данные браузера (`README.md:250`).
- В `state/` сохраняются URL чатов и названия сессий, что может раскрывать контекст задач (`README.md:245`, `README.md:250`).

## 7) crm-explorer (CRM интеграции)

Итог: CRM интеграции не найдено.

Проверка:
- Поиск по ключевым словам CRM (`bitrix|amocrm|crm|lead|deal|pipeline`) не дал релевантных кодовых интеграций.
- Совпадение `lead` встречено в комментарии `bin/cdp_chatgpt.py:298` (общий английский текст, не CRM).

Авторизация CRM:
- OAuth/client credentials/refresh token механизмы не найдены в коде.

## 8) webhook-analyzer (API, вебхуки, endpoints)

Итог: серверных HTTP endpoint/webhook receiver не найдено.

Что есть вместо этого:
- Локальные HTTP запросы к Chrome CDP на loopback (`127.0.0.1`) через `curl`/`urllib`:
  - `curl` к `/json/version`, `/json/list`, `/json/new`, `/json/activate`, `/json/close` (`bin/chatgpt_send:135`, `bin/chatgpt_send:548`, `bin/chatgpt_send:567`, `bin/chatgpt_send:960`, `bin/chatgpt_send:626`).
  - `urllib.request.urlopen` в Python helper (`bin/cdp_chatgpt.py:13`, `bin/cdp_chatgpt.py:15`).
- Приложений FastAPI/Flask/Django/Express и route handlers нет.

Проверка подписи/секретов webhook:
- Не найдено, т.к. webhook-приемников нет.

## 9) Безопасность и операционные наблюдения

Подтвержденные меры:
- CDP bind на localhost (`README.md:249`, `bin/chatgpt_send:691`).
- `umask 077` по умолчанию для приватности создаваемых файлов (`bin/chatgpt_send:25`).
- Исключение `state/` и логов из git (`.gitignore:2`, `.gitignore:9`).

Подтвержденные риски:
- `bin/chrome_no_sandbox` запускает браузер с `--no-sandbox` (`bin/chrome_no_sandbox:4`, `bin/chrome_no_sandbox:36`).
- UI automation хрупкая к изменениям DOM ChatGPT (`README.md:13`, `docs/WHY.md:40`).
- Неполное покрытие автоматическими тестами реальных браузерных сценариев.

## 10) Практические рекомендации

1. Добавить CI-сценарий smoke для `--doctor`, `--list-chats`, `--loop-*` в контейнере без реального ChatGPT UI (быстрый регресс CLI-логики).
2. Вынести JSON-операции сессий из inline Python в отдельный модуль для читаемости и unit-тестов.
3. Добавить опциональный режим логирования с уровнем (`info/debug`) и контролируемым путём лог-файла внутри `state/`.
4. Для прод-сценариев по возможности использовать обычный Chrome без `--no-sandbox` через `--chrome-path` (`README.md:251`).

## 11) Краткий итог

`chatgpt-send` — компактный локальный CLI-бридж без серверной части и без внешней БД. Основная надежность строится на retry/timeout и аккуратной работе с CDP. Критичные для безопасности данные локализованы в `state/` и исключены из git, но режим `--no-sandbox` и зависимость от меняющегося web UI остаются главными операционными рисками.
