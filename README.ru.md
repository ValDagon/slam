# S.L.A.M

**Swift Light Agent for Mac** — нативный headless AI-агент для **macOS (Apple Silicon)**: демон на Swift 6, общение через Telegram, локальная Ollama и `sandbox-exec` для команд модели.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-black.svg)](Package.swift)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)](https://swift.org)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

**Сайт:** [valdagon.github.io/slam](https://valdagon.github.io/slam/)

**Языки:** [English](README.md) · Русский · [Srpski](README.sr.md)

> **Альфа (0.1.0).** Уже можно пользоваться. Команды, границы песочницы и ключи конфига могут измениться до 1.0. Это личный демон, не продукт с SLA.

## Сильные стороны

- **Полностью Swift 6.** Исполняемый SPM-пакет, режим языка Swift 6, `-strict-concurrency=complete`. Разделяемое мутабельное состояние — в акторах или `Sendable`. Не Electron, не Node, не Python-обвязка.
- **Спроектирован под ограничения macOS**, а не портирован с Linux или из облака:
  - LaunchAgent с `KeepAlive` / `RunAtLoad` (процессом владеет launchd, не вечный `run` в Терминале)
  - Токен бота только в **macOS Keychain** (`kSecClassGenericPassword`) — никогда не git, не `.env`, не `config.json`
  - Команды модели через `sandbox-exec` (Seatbelt / SBPL), не Docker Desktop
  - QoS `.utility` / `.background` — простой на E-ядрах
  - Бюджет в спецификации: **RAM ≤ 100 МБ**, **CPU ≲ 1%** в простое
  - Ollama `keep_alive: 0` в каждом запросе — VRAM освобождается после ответа
  - Асинхронный `URLSession` (long poll + NDJSON); без busy-loop

Zero-GUI: у демона нет окна. Управление из Telegram (`/start`, `/help`, `/status`, `/model`, чат). Память — SQLite (GRDB, WAL, FTS5). Деструктивные команды требуют кнопку подтверждения.

## Сравнение с ZeroClaw

[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — сильный Rust-агент (Apache-2.0): один бинарник, long polling Telegram, pairing/allowlist, много провайдеров включая Ollama, широкая многоканальность. Этот проект его не «заменяет».

| | **S.L.A.M** | **ZeroClaw** (публичные материалы, авг 2026) |
|---|---|---|
| Стек | Swift 6 + фреймворки Apple + GRDB | Rust, один бинарник |
| Жизненный цикл на macOS | User LaunchAgent (`KeepAlive`, `RunAtLoad`, `ProcessType=Background`) | Кроссплатформенный демон (не launchd-first) |
| Изоляция инструментов | `sandbox-exec` SBPL (`deny default`, без сети у потомка) | Pairing, allowlist, workspace; опционально `runtime.kind="docker"` |
| Секреты | Токен Telegram **только** в Keychain | В этом классе часто конфиг-файл — для *этого* демона это антипаттерн |
| Каналы в v1 | Только Telegram | 15–30+ (Telegram, Discord, Slack, iMessage, …) |
| VRAM локальной модели | `keep_alive: 0` + idle-unloader | Ollama поддерживается; политика VRAM своя |
| Простой | Спека + свои замеры (≤ 100 МБ / ≲ 1%) | Вендорская заявка порядка нескольких МБ — чужие цифры не копируем |

Честный обмен: у ZeroClaw больше каналов, cron/SOP и мультиагентность. S.L.A.M — **нативный для macOS** демон Telegram + локальная Ollama с жёстким бюджетом ресурсов и Seatbelt вместо Docker.

Источники: [research/competitors.ru.md](research/competitors.ru.md).

## Ограничение записи в workspace — только альфа

Сейчас профиль Seatbelt (FR-22) нарочно узкий:

- **Чтение:** системные пути для exec + каталог workspace (`working_dir`, по умолчанию `~/.local/share/slam/workspace`)
- **Запись:** только `WORKING_DIR/tmp` (и `/dev/null`)
- **Сеть:** запрещена внутри песочницы
- **Чувствительные деревья** (`~/.ssh`, `~/.aws`, Keychain, `~/Documents`) явно запрещены

Это **безопасный дефолт альфы**, не вечный предел продукта. Позже область расширят и/или сделают настраиваемой. `write_file` и редиректы вне `tmp/` в этом релизе отклоняются специально.

## Установка как сервиса (около 10 минут)

Нужны: macOS Apple Silicon, Xcode / Swift 6.3+, [Ollama](https://ollama.com) с моделью.

```bash
git clone https://github.com/ValDagon/slam.git
cd slam
./install.sh
```

Сборка release → `~/.local/bin/slam`, plist в `~/Library/LaunchAgents/com.local.slam.plist`, bootstrap `gui/$(id -u)`, старт при логине. Спросит токен BotFather, если Keychain пуст.

```bash
./install.sh stop | start | restart | status | logs | uninstall | purge
```

Ручной kickstart: `launchctl kickstart -k gui/$(id -u)/com.local.slam`.

Дальше:

```bash
ollama pull qwen2.5:7b
mkdir -p ~/.config/slam
```

Числовой Telegram ID — в `~/.config/slam/config.json` (ниже). Первый ID в списке — владелец.

## Быстрый старт (без LaunchAgent)

```bash
swift build && swift test
swift run slam set-token          # токен @BotFather → Keychain
# config.json с telegram_allowlist
ollama pull qwen2.5:7b
swift run slam run
```

## Конфигурация и Keychain

`~/.config/slam/config.json` — **без секретов**. Обязателен `telegram_allowlist`. Остальное имеет значения по умолчанию.

| Ключ | Смысл (по умолчанию) |
|---|---|
| `telegram_allowlist` | ID с доступом (первый = владелец) |
| `model` | `qwen2.5:7b` |
| `working_dir` | workspace песочницы |
| `max_context_messages` | `20` |
| `idle_unload_minutes` | `10` |
| `sandbox_enabled` | `true` |
| `command_timeout_seconds` | `30` |
| `confirmation_timeout_seconds` | `600` |
| `use_native_tools` | `true` (Ollama `write_file` / `run_shell`; fallback — fence `` ```run ``) |
| `ollama_url` / `system_prompt` / `context_budget_chars` / `storage_quota_bytes` / `destructive_patterns` | опционально |

**Токен:** Keychain `service=com.local.slam`, `account=telegram-bot-token`. Не вставляйте его в issues, README или конфиг.

| Путь | Содержимое |
|---|---|
| `~/.config/slam/config.json` | конфиг |
| Keychain `com.local.slam` / `telegram-bot-token` | токен бота |
| `~/Library/LaunchAgents/com.local.slam.plist` | LaunchAgent |
| `~/.local/bin/slam` | release-бинарник |
| `~/.local/share/slam/agent.sqlite*` | БД |
| `~/.local/state/slam/logs/` | логи демона и launchd |

### Эксплуатация

- **Здоровье:** `/status` в Telegram (uptime, RSS/CPU, БД, песочница)
- **Логи:** `./install.sh logs` или `~/.local/state/slam/logs/slam.log`
- **Смена токена:** отозвать у @BotFather → `./install.sh stop` → `set-token` → `./install.sh start`
- **Смена модели:** `/model <name>` или конфиг + restart
- **Один экземпляр:** второй процесс не стартует; повторяющиеся HTTP 409 — другой poller с тем же токеном
- **Диалог Keychain:** каждый `./install.sh` заново ad-hoc подписывает бинарник. Скрипт вызывает `repair-keychain-acl`; если macOS спросит — **Always Allow** один раз
- **Снос сервиса:** `./install.sh uninstall` (останавливает LaunchAgent, удаляет plist и `~/.local/bin/slam`; данные остаются)
- **Вычистить эту машину:** `./install.sh purge` — плюс конфиг, SQLite/workspace, логи, кэши URLSession, crash-репорты и запись Keychain (`clear-token`). Репозиторий и Ollama не трогает. Токен бота отзовите у @BotFather, если больше не нужен.

CLI: `slam set-token` · `clear-token` · `repair-keychain-acl` · `run` · `version`. В боте: `/help`.

## Статус

Альфа. Шлюз: `swift build` и `swift test` — **121 тест / 22 сюиты** на снимке, с которого открыт этот репозиторий. Исходящие сообщения Telegram — HTML `parse_mode` (вывод команд в `<pre>`, подсказки курсивом); модель разметку не пишет.

## Документация

- [Лендинг](https://valdagon.github.io/slam/)
- [Спецификация](docs/SPEC.ru.md) · [English](docs/SPEC.md) · [Srpski](docs/SPEC.sr.md)
- [Конкуренты и нативные практики](research/competitors.ru.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Changelog](CHANGELOG.md)

Переводы гайдов: [CONTRIBUTING.ru.md](CONTRIBUTING.ru.md), [SECURITY.ru.md](SECURITY.ru.md). Канон GitHub-файлов сообщества — английский.

## Лицензия

[MIT](LICENSE)
