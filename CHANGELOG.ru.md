# Журнал изменений

Канон: [CHANGELOG.md](CHANGELOG.md) (английский, Keep a Changelog).

## [Unreleased]

Альфа на `main`. Запись песочницы только в `WORKING_DIR/tmp` — консервативный дефолт, **не** предел 1.0.

- Ребренд: продукт **S.L.A.M** (Swift Light Agent for Mac). CLI и пути на диске — `slam`. Репозиторий [`ValDagon/slam`](https://github.com/ValDagon/slam), Pages [valdagon.github.io/slam](https://valdagon.github.io/slam/). `./install.sh` переносит старый `swift-agent`.
- `./install.sh purge` — полный снос с машины (сервис, данные, Keychain). `uninstall` данные оставляет.

## [0.1.0-alpha] — 2026-08-26

Первый публичный снимок: Swift 6 SPM, LaunchAgent, Telegram HTML, локальная Ollama (`keep_alive: 0`, native tools), SQLite (GRDB), `sandbox-exec`, токен только в Keychain.
