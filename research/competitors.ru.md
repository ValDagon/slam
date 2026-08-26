# Конкуренты и нативные практики macOS

Публичные заметки для S.L.A.M (срез **2026-08-25**). Числа stars и RAM конкурентов — **как заявляют сами проекты** на эту дату, не независимый бенчмарк.

**Переводы:** [English](competitors.md) · [Srpski](competitors.sr.md)

---

## 1. Сравнение

| Критерий | ZeroClaw | OpenClaw | PicoClaw |
|---|---|---|---|
| Язык | Rust, один бинарник | TypeScript / Node.js gateway | Go, один статический бинарник |
| Репо (авг 2026) | [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) · ~32.6k stars · Apache-2.0 | [openclaw/openclaw](https://github.com/openclaw/openclaw) · ~387k stars · лицензия «Other» | [sipeed/picoclaw](https://github.com/sipeed/picoclaw) · MIT |
| RAM в простое (заявка) | `<5MB` (вендорский `/usr/bin/time -l`) | `>1GB` в таблице ZeroClaw — считать **вендорским уколом**, не лабораторным числом | заявлено `<10MB` |
| Telegram | Да. Bot API long-polling (`getUpdates`, offset, timeout 30s, backoff, 409). Плюс Discord/Slack/Matrix/…, 15–30+ каналов | Да. grammY; long polling по умолчанию; pairing, allowlist | Да. 16–18+ чатов включая Telegram |
| Планировщик | CLI cron + SOP | cron в SQLite + heartbeat | Встроенный планировщик |
| Память | Подключаемый backend | Markdown `MEMORY.md` / `USER.md`; truncate при >20k | Локальные файлы + membench |
| Инструменты / песочница | shell/HTTP/MCP; pairing, allowlist, workspace; опционально `runtime.kind="docker"` | Skills/plugins; изоляция сессий | tools, MCP, sub-agents |
| Провайдеры | ~20–22+ включая **Ollama** | Много через конфиг | 30+ unified interface |
| Что перенять | Long-poll + 409; сменяемые провайдеры; pairing; дисциплина размера | Heartbeat вместо кучи таймеров; flush памяти; бюджет контекста | Свои замеры footprint; один бинарник |

Цифры idle-RAM ZeroClaw и `>1GB` у OpenClaw **не** копируются в спецификацию S.L.A.M. Мы публикуем свой бюджет (≤ 100 МБ / ≲ 1%) и свои замеры.

## 2. Нативные практики, которые здесь используются

- **launchd:** user LaunchAgent, `KeepAlive={SuccessfulExit:false}`, `RunAtLoad`, `ThrottleInterval≥10`, `ProcessType=Background`, `launchctl bootstrap gui/$(id -u)`.
- **Seatbelt / `sandbox-exec`:** `(deny default)` + `-D WORKING_DIR` / `WORKING_TMP`. Запись только в `WORKING_DIR/tmp` в **альфе**. `sandbox-exec` формально deprecated. Docker Desktop как песочница для лёгкого личного демона отвергнут.
- **Keychain:** GenericPassword, add-or-update, токен не в конфиге и не в `.env`.
- **URLSession.bytes:** NDJSON и long-poll без busy-loop.
- **Telegram:** один poller на токен; `deleteWebhook` перед `getUpdates`; offset в БД.
- **GRDB + WAL + FTS5 unicode61** и часовой checkpoint/vacuum/optimize.
- **Ollama:** `keep_alive` top-level; `0` в каждом запросе; idle-unloader с пустым `messages`.
- **QoS:** `.utility` цикл демона, `.background` обслуживание БД (E-ядра), `.userInitiated` сообщение пользователя.
- **Swift 6 complete concurrency:** акторы, `Sendable`, без `@MainActor`.

## 3. Выводы для этого демона

1. Telegram — канал, не ядро; в v1 он один сознательно.
2. Rust/Go доказали класс единиц МБ; Swift 6 может жить в **десятках МБ**, если оставаться нативным и мерить.
3. Эталон цикла Telegram: timeout 30, offset, backoff, 409 как второй инстанс, allowlist до модели.
4. Память не только в RAM; SQLite — источник истины.
5. Песочница: deny-default SBPL, запись tmp-only в альфе (потом расширим).
6. Секреты только в Keychain.
7. Явный `keep_alive: 0` + idle-unloader для VRAM ноутбука.
8. `ProcessType=Background` согласует launchd и GCD QoS.
9. WAL-гигиена по таймеру; full jitter на reconnect; single-instance lock.
10. Вендорский RAM конкурентов не тащить в README как факт.

## 4. Источники

Те же URL, что в [competitors.md](competitors.md).
