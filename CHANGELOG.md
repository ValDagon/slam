# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Alpha continues on `main`. Workspace write scope (`WORKING_DIR/tmp` only) is still the conservative default and is **not** a 1.0 product limit.

- Rebrand: product name is **S.L.A.M** (Swift Light Agent for Mac). CLI and on-disk layout are `slam`. GitHub repo is [`ValDagon/slam`](https://github.com/ValDagon/slam); Pages is [valdagon.github.io/slam](https://valdagon.github.io/slam/). `./install.sh` migrates a previous `swift-agent` install.
- `./install.sh purge` (alias `uninstall --purge`): full local wipe — LaunchAgent, binary, config, SQLite/workspace, logs, URLSession caches, crash reports, Keychain item. `uninstall` still keeps data.
- CLI `slam clear-token` deletes both Keychain variants without printing the secret.

## [0.1.0-alpha] — 2026-08-26

First public snapshot of the native macOS daemon:

- Swift 6 SPM executable, strict concurrency, LaunchAgent install via `./install.sh`
- Telegram long polling, HTML `parse_mode` for structured replies (`TelegramFormat`)
- Local Ollama (`keep_alive: 0`, native tools `write_file` / `run_shell`, fence fallback)
- SQLite memory (GRDB WAL + FTS5), disk quota and maintenance tick
- `sandbox-exec` Seatbelt profile, HITL confirmation for destructive commands
- Bot token in macOS Keychain only

[Unreleased]: https://github.com/ValDagon/slam
[0.1.0-alpha]: https://github.com/ValDagon/slam
