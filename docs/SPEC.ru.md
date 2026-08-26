# Спецификация · S.L.A.M

Нативный автономный AI-агент под macOS (Apple Silicon). Статус: **альфа (0.1.0)** — этапы ниже реализованы; API и границы песочницы могут измениться до 1.0.

**Переводы:** [English](SPEC.md) · [Srpski](SPEC.sr.md)

Это продуктовая спецификация (функциональные требования, архитектура, non-goals). Не журнал сессий.

---

## 1. North-star

Один резидентный процесс macOS (Apple Silicon, класс 16 ГБ), дешёвый в простое: RAM ≤ 100 МБ, CPU ≲ 1% в ожидании, работа на E-ядрах там, где позволяет QoS. Управление только через Telegram. Интеллект — локальная Ollama (по умолчанию Qwen 2.5 7B). Память — SQLite. Команды модели — только в песочнице Seatbelt; деструктивные шаблоны требуют подтверждения человеком.

## 2. Платформа и ресурсный бюджет

| Параметр | Требование | Как проверяем |
|---|---|---|
| Платформа | macOS, Apple Silicon (M1+, 16 ГБ unified) | сборка arm64 |
| Формат | SPM executable, без GUI | `swift build` без AppKit |
| RAM в простое | ≤ 100 МБ RSS | `/status` + Activity Monitor / `footprint` |
| CPU в простое | ≲ 1% (блокировка на I/O между long-poll) | замер за несколько минут |
| Язык | Swift 6, `-strict-concurrency=complete`, async/await, акторы | `Package.swift`, зелёный `swift build` |
| Зависимости | только GRDB.swift; сеть / Keychain / процессы — нативные фреймворки | `Package.resolved` |
| QoS | Long poll, JSON, SQLite, процессы → `.utility`; обслуживание БД → `.background`; сообщение пользователя → `.userInitiated` | ревью |

Заявки конкурентов по RAM — вендорские. В эту спецификацию входят только **наши** замеры.

## 3. Архитектура

Схема: [SPEC.md](SPEC.md) §3 (тот же mermaid).

| Модуль | Тип | Ответственность |
|---|---|---|
| `AgentActor` | actor | машина состояний, очередь апдейтов, маршрутизация |
| `TelegramListener` | nonisolated service | цикл `getUpdates`, backoff, детект 409 |
| `TelegramPublisher` | nonisolated service | `sendMessage` / троттлинг `editMessageText` |
| `OllamaClient` | nonisolated service | `POST /api/chat`, NDJSON через `URLSession.bytes.lines` |
| `DatabaseManager` | actor | GRDB `DatabasePool`, история, FTS5, квоты, offset |
| `ProcessRunner` | nonisolated service | `Foundation.Process` + `sandbox-exec`, HITL |
| `KeychainStore` | struct | SecItem add/update/read токена |
| `MaintenanceLoop` | Task | суммаризация, checkpoint/vacuum |
| `DaemonMain` | entry | конфиг, Keychain, single-instance, старт циклов |

Инвариант: разделяемое мутабельное состояние только в акторах; сообщения — `Sendable`; сервисы `nonisolated`; `@MainActor` нет.

## 4. Функциональные требования

### 4.1 Жизненный цикл

- **FR-1** LaunchAgent `~/Library/LaunchAgents/com.local.slam.plist`: `KeepAlive={SuccessfulExit:false}`, `ThrottleInterval≥10`, `RunAtLoad=true`, `ProcessType=Background`, логи в `~/.local/state/slam/logs/`. Установка `launchctl bootstrap gui/$(id -u)` (`install.sh`). Без ручного fork.
- **FR-2** Single-instance: второй процесс выходит с понятной ошибкой. HTTP 409 от Telegram — «другой poller».
- **FR-3** Конфиг без секретов: `~/.config/slam/config.json`.

### 4.2 Telegram

- **FR-4** Только нативный `URLSession`. Long polling `getUpdates`: `timeout=30`, `allowed_updates`, `offset` в SQLite.
- **FR-5** При старте: `getWebhookInfo` → `deleteWebhook`, если webhook активен.
- **FR-6** Backoff: старт 2 с, потолок 300 с, ×2, **full jitter**.
- **FR-7** Allowlist Telegram ID. Первый `/start` незнакомца — офер паринга; владелец добавляет через `/allow` или конфиг.
- **FR-8** Команды: `/start`, `/help`, `/status`, `/model <name>`, `/allow <id>`, `/deny <id>`. Остальной текст — ход модели.
- **FR-9** Стриминг одним сообщением, `editMessageText` с троттлингом ~1.5–2 с, `sendChatAction(typing)` ~каждые 4 с, курсор `▍`.

### 4.3 Keychain

- **FR-10** Токен при старте из Keychain (`kSecClassGenericPassword`, service `com.local.slam`, account `telegram-bot-token`). Файлы / plist / env запрещены.
- **FR-11** Add-or-update: `SecItemAdd` → при дубликате `SecItemUpdate`. CLI: `slam set-token`.

### 4.4 Ollama

- **FR-12** `POST http://localhost:11434/api/chat`, модель по умолчанию `qwen2.5:7b`, `"stream": true`, `"keep_alive": 0` **в каждом запросе** (top-level).
- **FR-13** Поток: `URLSession.bytes(for:)` + NDJSON; HTTP 200 до чтения; отмена — отменой Task.
- **FR-14** Контекст: последние N сообщений + фрагменты FTS5 + системный промпт, truncate по бюджету символов.
- **FR-15** Idle-unloader: после M минут простоя пустой `messages:[]` + `keep_alive: 0`.
- **FR-16** Протокол `ModelProvider` над Ollama. В v1 одна реализация.

### 4.5 База

- **FR-17** GRDB `DatabasePool` (WAL), `DatabaseMigrator`.
- **FR-18** Таблицы v1: `sessions`, `messages` (+ FTS5 unicode61), `kv`, `pending_confirmations`, `meta`.
- **FR-19** Квота: min(10% свободного места тома, 20 ГБ). При 85% — фоновая суммаризация и `incremental_vacuum`.
- **FR-20** Раз в час (`.background`): `wal_checkpoint(TRUNCATE)`, `incremental_vacuum`, `PRAGMA optimize`.

### 4.6 Команды и песочница

- **FR-21** Нативные tools Ollama (`write_file`, `run_shell`) и fallback `` ```run ``. Исполнение: `Foundation.Process` + `/usr/bin/sandbox-exec`. Пути `write_file` — строго внутри `WORKING_DIR/tmp`.
- **FR-22** SBPL с `-D WORKING_DIR` / `-D WORKING_TMP`: `(deny default)`; чтение — системные библиотеки + `WORKING_DIR`; **запись — только `WORKING_DIR/tmp`**; `(deny network*)`; явный deny `~/.ssh`, `~/.aws`, `~/Library/Keychains`, `~/Documents`.

  **Ограничение записи — только альфа.** Текущий write-scope — консервативный безопасный дефолт 0.1.0, не вечный предел продукта. Позже область расширят и/или сделают настраиваемой.

- **FR-23** HITL: деструктивные шаблоны ждут inline-кнопок, таймаут 10 минут. stdout/stderr/код — в БД и в чат.
- **FR-24** Smoke `sandbox-exec` на буте; при отказе канал команд выключен, демон жив.

## 5. Не входит в v1

- Другие сети (Discord, WhatsApp, iMessage, …) — только Telegram.
- Webhook Telegram.
- Векторные БД / embeddings — достаточно FTS5.
- Пользовательский cron/SOP — внутренние тики есть, расписания пользователя в backlog.
- GUI, облачные провайдеры моделей.

## 6. Что взято из поля

| Идея | Обычный источник | У нас |
|---|---|---|
| Long-poll 30 с + backoff + 409 | канал Telegram ZeroClaw | FR-4 / FR-6 / FR-2 |
| Паринг / allowlist | ZeroClaw, OpenClaw | FR-7 |
| Стрим правками одного сообщения | ZeroClaw (`editMessageText`) | FR-9 |
| Бюджет контекста | OpenClaw MEMORY.md | FR-14 |
| Idle-выгрузка VRAM | гигиена локального GPU | FR-15 |
| Протокол провайдера | traits ZeroClaw | FR-16 |
| Свои замеры footprint | урок PicoClaw membench | §2 |
| WAL-гигиена | практика SQLite | FR-20 |

## 7. Этапы (сделаны в альфе)

| Этап | Содержание | DoD |
|---|---|---|
| 1. Каркас | SPM, Keychain, long poll, allowlist | зелёный `swift test` |
| 2. Модель | стрим Ollama, `keep_alive:0`, unloader | стрим в чат; веса выгружаются |
| 3. Хранилище | GRDB, FTS5, квоты | история после рестарта |
| 4. Исполнение | `sandbox-exec`, HITL | запись вне tmp запрещена |
| 5. Сервис | `install.sh`, `/status`, README | LaunchAgent после логина; ≤ 10 мин |
| 6. Проверка | сквозной прогон по этой спеке | `swift test` + живой LaunchAgent + Telegram/Ollama |

## 8. Риски

| Риск | Митигация |
|---|---|
| `sandbox-exec` формально deprecated | smoke FR-24 |
| Бюджет 100 МБ тесноват | ранний замер; один пул |
| Rate limit Telegram | троттлинг FR-9 |
| Слабый tool-call у 7B | fence + HITL |
| Два экземпляра | FR-2 + диагностика 409 |

## 9. Источники

[research/competitors.ru.md](../research/competitors.ru.md).
