# Codex CLI TUI: Swarm Status Provider (MVP Design)

## Goal

Показать статусы дочерних агентов (роя) прямо в TUI Codex CLI, в зоне нижнего статуса/`Working (...)`, а не через текстовые сообщения в чате.

Пример UX:

- `Swarm: 2/5 done · 2 running · 1 failed`
- `Борис: running · syntax check`
- `Маша: done · tests OK`

## Why this is needed

Сейчас координация child-агентов работает, но live-статусы видны только через логи/мониторинг/сообщения. Для оператора это хуже, чем нативная строка статуса TUI.

В `openai/codex` уже есть:

- настраиваемая status line (`/statusline`)
- unified-exec footer summary (для фоновых терминалов)

Это позволяет сделать MVP без большой архитектуры плагинов.

## Current upstream hooks (confirmed)

Основные точки в `openai/codex` (Rust TUI):

- `codex-rs/tui/src/chatwidget.rs`
  - `refresh_status_line()`
  - `set_status_line(...)`
  - `sync_unified_exec_footer()`
- `codex-rs/tui/src/bottom_pane/mod.rs`
  - `set_unified_exec_processes(...)`
  - `sync_status_inline_message(...)`
  - рендер дополнительной footer-строки
- `codex-rs/tui/src/bottom_pane/unified_exec_footer.rs`
  - готовый паттерн компактного footer summary
- `codex-rs/tui/src/bottom_pane/status_line_setup.rs`
  - enum `StatusLineItem` и `/statusline` picker
- `codex-rs/core/src/config/types.rs`
  - `Tui` config struct (`status_line`)
- `codex-rs/core/src/config/mod.rs`
  - нормализованный runtime config (`tui_status_line`)

## Recommendation (MVP)

Рекомендую **не** делать универсальный plugin API для footer на первом шаге.

Рекомендую сделать **MVP provider через файл JSON**:

- Codex TUI читает один JSON-файл статуса роя (polling)
- Парсит агрегированный статус + список агентов
- Рисует summary в footer/status line

Это быстро, fail-safe и не требует IPC/сокетов/демонов.

## JSON contract (MVP)

Файл, например: `/tmp/codex-swarm-status.json`

```json
{
  "version": "swarm-status.v1",
  "updated_at": "2026-02-24T17:10:00Z",
  "session_id": "optional-coordinator-session",
  "summary": {
    "total": 5,
    "running": 2,
    "done": 2,
    "failed": 1,
    "waiting": 0
  },
  "agents": [
    {
      "id": "agent-1",
      "name": "Борис",
      "state": "running",
      "task": "syntax check",
      "updated_at": "2026-02-24T17:09:58Z"
    },
    {
      "id": "agent-2",
      "name": "Маша",
      "state": "done",
      "task": "swarm prompt test",
      "result": "OK",
      "updated_at": "2026-02-24T17:09:54Z"
    }
  ]
}
```

## Rendering behavior (MVP)

### 1) Compact summary in status line item (`Swarm`)

Добавить новый item в `/statusline`:

- `swarm`

Рендер значения:

- `swarm 2/5 done · 2 run · 1 fail`

Если данных нет:

- item опускается (`None`) без ошибок (как `git-branch`)

### 2) Optional extra footer row (only while active)

По аналогии с `UnifiedExecFooter`, добавить `SwarmFooter`:

- показывает 1 строку с деталями top-N агентов
- только если есть активные агенты (`running/waiting`) или недавний fail

Пример:

- `  Борис: running · syntax check | Маша: done · tests OK | Олег: failed · no exit file`

Если footer row слишком длинная:

- аккуратно truncate по ширине (как `UnifiedExecFooter`)

## Config (MVP)

Добавить в `tui` секцию:

```toml
[tui]
swarm_status_file = "/tmp/codex-swarm-status.json"
swarm_status_poll_ms = 1000
swarm_status_footer = true
```

### Proposed fields

В `codex-rs/core/src/config/types.rs` (`struct Tui`):

- `swarm_status_file: Option<PathBuf>`
- `swarm_status_poll_ms: Option<u64>` (default `1000`)
- `swarm_status_footer: Option<bool>` (default `true`)

В runtime config (`codex-rs/core/src/config/mod.rs`):

- нормализованные поля `tui_swarm_status_*`

## Data flow (MVP)

1. Координатор (главный агент) пишет JSON-файл статуса роя
2. Codex TUI polling-задача читает файл с интервалом
3. При изменении данных отправляет `AppEvent::SwarmStatusUpdated(...)`
4. `App` передает данные в `ChatWidget` / `BottomPane`
5. `ChatWidget.refresh_status_line()` включает item `swarm`
6. `BottomPane` (опционально) рисует `SwarmFooter`

## Minimal upstream patch plan (files)

### A. Config and schema

1. `codex-rs/core/src/config/types.rs`
- добавить поля `tui.swarm_status_file`, `tui.swarm_status_poll_ms`, `tui.swarm_status_footer`

2. `codex-rs/core/src/config/mod.rs`
- добавить runtime-поля в `Config`
- протянуть значения из `Tui`

### B. App events + polling

3. `codex-rs/tui/src/app_event.rs`
- добавить `AppEvent::SwarmStatusUpdated { snapshot: Option<SwarmStatusSnapshot> }`

4. `codex-rs/tui/src/app.rs`
- при старте TUI (если `swarm_status_file` задан) запустить polling task/thread
- polling:
  - читает файл
  - парсит JSON
  - при diff -> `AppEvent::SwarmStatusUpdated`
  - при parse error/log I/O error -> fail-soft (warning/log, не ломать TUI)
- обработчик события:
  - `chat_widget.set_swarm_status(snapshot)`
  - `refresh_status_line()`

### C. Status line item + rendering

5. `codex-rs/tui/src/bottom_pane/status_line_setup.rs`
- добавить `StatusLineItem::Swarm`
- описание + preview (`"swarm 2/5 done · 2 run"`)

6. `codex-rs/tui/src/chatwidget.rs`
- хранить `swarm_status: Option<SwarmStatusSnapshot>`
- добавить `set_swarm_status(...)`
- расширить `status_line_value_for_item(...)` для `StatusLineItem::Swarm`

### D. Footer row (optional but strongly recommended)

7. `codex-rs/tui/src/bottom_pane/swarm_footer.rs` (новый)
- по образцу `unified_exec_footer.rs`
- методы:
  - `set_snapshot(...)`
  - `is_empty()`
  - `summary_text()`
  - `render_lines(width)`

8. `codex-rs/tui/src/bottom_pane/mod.rs`
- добавить `swarm_footer: SwarmFooter`
- обновление snapshot
- рендер row:
  - не дублировать, если status-row уже показывает inline swarm и места мало
  - показывать row при активном рое/ошибках (policy)

## Failure policy (important)

Fail-soft, never break TUI:

- файл отсутствует -> просто не показывать swarm
- JSON битый -> warning в лог, последнее валидное состояние можно держать (или сбросить)
- JSON устарел -> показывать `swarm stale` / либо скрывать item

Рекомендую для MVP:

- если `updated_at` старше `10s`, показывать:
  - `swarm stale`
  - и footer не рисовать

## Integration with our coordinator (chatgpt-send side)

С нашей стороны (координатор роя) достаточно писать один JSON-файл:

- при запуске child -> `running`
- при завершении -> `done/failed`
- при heartbeat -> обновлять `updated_at` и task label

Никаких изменений в протоколе child-агентов не требуется для MVP.

## Tests (minimum)

### Codex upstream tests

1. `status_line_setup`:
- новый item `swarm` виден в picker

2. `chatwidget`:
- `StatusLineItem::Swarm` -> `None` when no snapshot
- корректный текст при валидном snapshot
- stale snapshot -> `swarm stale` (если выберем эту политику)

3. `swarm_footer` snapshots:
- empty
- one running agent
- many agents (truncation)

4. polling/parser:
- valid file
- invalid JSON
- deleted file
- unchanged file (no redundant redraw/event)

## Rollout order (pragmatic)

1. `Swarm` item в status line (без footer)
2. polling JSON file
3. `SwarmFooter` row
4. polish (colors/icons/truncation tuning)

Так мы быстро получим полезный UI уже на шаге 1-2.

## Why this is the right first step

- Нативно в TUI (как ты хочешь)
- Без костылей через чат-сообщения
- Без тяжёлого plugin API
- Легко дебажить (обычный JSON-файл)
- Совместимо с вашим роевым координатором уже сейчас

## References

- OpenAI Codex issue: custom status line request (`#2926`)
- OpenAI Codex issue: status engine / external provider request (`#3414`, duplicate)
- Upstream source paths listed above from `openai/codex` (`codex-rs/tui`, `codex-rs/core/src/config`)
