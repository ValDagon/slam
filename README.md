# S.L.A.M

**Swift Light Agent for Mac** — native headless AI agent for **macOS (Apple Silicon)**: a Swift 6 daemon you talk to over Telegram, with local Ollama for inference and `sandbox-exec` for model-issued commands.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-black.svg)](Package.swift)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)](https://swift.org)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

**Site:** [valdagon.github.io/slam](https://valdagon.github.io/slam/)

**Languages:** English · [Русский](README.ru.md) · [Srpski](README.sr.md)

> **Alpha (0.1.0).** Usable today. Commands, sandbox scope, and config keys may change before 1.0. Treat this as a personal daemon, not a 1.0 product.

## Killer features

- **Fully Swift 6.** SPM executable, Swift 6 language mode, `-strict-concurrency=complete`. Shared mutable state lives in actors or is `Sendable`. Not Electron, Node, or Python glue.
- **Designed around macOS constraints**, not ported from Linux or the cloud:
  - LaunchAgent with `KeepAlive` / `RunAtLoad` (launchd owns the process; no forever-`run` in Terminal)
  - Bot token in **macOS Keychain** (`kSecClassGenericPassword`) — never git, `.env`, or `config.json`
  - Model-issued shell via `sandbox-exec` (Seatbelt / SBPL), not Docker Desktop
  - QoS `.utility` / `.background` so idle work stays on E-cores
  - Idle budget in the spec: **RAM ≤ 100 MB**, **CPU ≲ 1%**
  - Ollama `keep_alive: 0` on every request so VRAM is released after each answer
  - `URLSession` async APIs (long poll + NDJSON stream); no busy loops

Zero-GUI: the daemon has no window. You drive it from Telegram (`/start`, `/help`, `/status`, `/model`, chat). Memory is SQLite (GRDB, WAL, FTS5). Destructive commands need a human-in-the-loop button.

## Compared with ZeroClaw

[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) is a strong Rust agent (Apache-2.0): one binary, Telegram long-polling, pairing/allowlists, many model providers including Ollama, and a large multi-channel surface. This project does not try to replace that.

| | **S.L.A.M** | **ZeroClaw** (from public docs, Aug 2026) |
|---|---|---|
| Stack | Swift 6 + Apple frameworks + GRDB | Rust, single static-ish binary |
| macOS lifecycle | User LaunchAgent (`KeepAlive`, `RunAtLoad`, `ProcessType=Background`) | Cross-platform daemon (not launchd-first) |
| Isolation of tools | `sandbox-exec` SBPL (`deny default`, no network from the child) | Pairing, allowlists, workspace scoping; optional `runtime.kind="docker"` |
| Secrets | Telegram token **only** in Keychain | Typical of the class: config-file secrets — we treat that as an anti-pattern *for this daemon* |
| Channels in v1 | Telegram only | 15–30+ (Telegram, Discord, Slack, iMessage, …) |
| Local GPU hygiene | `keep_alive: 0` every chat + idle unloader | Ollama supported; VRAM policy is product-specific |
| Idle resources | Spec + own measurements (≤ 100 MB / ≲ 1%) | Vendor claim on the order of a few MB — we do not reuse competitor numbers |

Fair trade-off: ZeroClaw is far ahead on channels, cron/SOP, and multi-agent. S.L.A.M is a **macOS-native** Telegram + local-Ollama daemon with a hard resource budget and Seatbelt instead of Docker.

See [research/competitors.md](research/competitors.md) for sources.

## Workspace writes are alpha-only

Today the Seatbelt profile (FR-22) is conservative on purpose:

- **Read:** system paths needed to exec + the workspace directory (`working_dir`, default `~/.local/share/slam/workspace`)
- **Write:** only `WORKING_DIR/tmp` (plus `/dev/null`)
- **Network:** denied inside the sandboxed child
- **Sensitive trees** (`~/.ssh`, `~/.aws`, Keychains, `~/Documents`) are explicitly denied

That write scope is an **alpha safety default**, not a permanent product limit. Later versions will widen it and/or make it configurable. `write_file` and shell redirects that land outside `tmp/` are denied by design *in this release*.

## Install as a service (about 10 minutes)

Needs: macOS Apple Silicon, Xcode / Swift 6.3+, [Ollama](https://ollama.com) with a model.

```bash
git clone https://github.com/ValDagon/slam.git
cd slam
./install.sh
```

Builds a release binary → `~/.local/bin/slam`, writes `~/Library/LaunchAgents/com.local.slam.plist`, bootstraps `gui/$(id -u)`, starts at login. Prompts for a BotFather token if Keychain is empty.

```bash
./install.sh stop | start | restart | status | logs | uninstall | purge
```

Manual kickstart: `launchctl kickstart -k gui/$(id -u)/com.local.slam`.

Then:

```bash
ollama pull qwen2.5:7b
mkdir -p ~/.config/slam
```

Put your Telegram numeric user id in `~/.config/slam/config.json` (see below). First allowed id is the owner.

## Quick start (no LaunchAgent)

```bash
swift build && swift test
swift run slam set-token          # @BotFather token → Keychain
# write config.json with telegram_allowlist
ollama pull qwen2.5:7b
swift run slam run
```

## Configuration and Keychain

`~/.config/slam/config.json` holds **non-secrets only**. Required: `telegram_allowlist`. Everything else has defaults.

| Key | Meaning (default) |
|---|---|
| `telegram_allowlist` | Allowed Telegram user IDs (first = owner) |
| `model` | `qwen2.5:7b` |
| `working_dir` | Sandbox workspace |
| `max_context_messages` | `20` |
| `idle_unload_minutes` | `10` |
| `sandbox_enabled` | `true` |
| `command_timeout_seconds` | `30` |
| `confirmation_timeout_seconds` | `600` |
| `use_native_tools` | `true` (Ollama `write_file` / `run_shell`; fence `` ```run `` is fallback) |
| `ollama_url` / `system_prompt` / `context_budget_chars` / `storage_quota_bytes` / `destructive_patterns` | optional |

**Token:** Keychain `service=com.local.slam`, `account=telegram-bot-token`. Never paste it into issues, README, or config.

| Path | Contents |
|---|---|
| `~/.config/slam/config.json` | config |
| Keychain `com.local.slam` / `telegram-bot-token` | bot token |
| `~/Library/LaunchAgents/com.local.slam.plist` | LaunchAgent |
| `~/.local/bin/slam` | release binary |
| `~/.local/share/slam/agent.sqlite*` | database |
| `~/.local/state/slam/logs/` | daemon + launchd logs |

### Operations

- **Health:** `/status` in Telegram (uptime, RSS/CPU, DB, sandbox)
- **Logs:** `./install.sh logs` or `~/.local/state/slam/logs/slam.log`
- **Rotate token:** revoke at @BotFather → `./install.sh stop` → `set-token` → `./install.sh start`
- **Change model:** `/model <name>` or config + restart
- **Single instance:** a second process exits; repeated HTTP 409 means another poller shares the token
- **Keychain dialog:** each `./install.sh` ad-hoc-signs a new binary. `install.sh` runs `repair-keychain-acl`; if macOS asks, click **Always Allow** once
- **Remove service:** `./install.sh uninstall` (stops LaunchAgent, deletes plist + `~/.local/bin/slam`; data kept)
- **Wipe this Mac:** `./install.sh purge` — also deletes config, SQLite/workspace, logs, URLSession caches, crash reports, and the Keychain item (`clear-token`). Does not touch the git clone or Ollama. Revoke the bot token at @BotFather if you are done with it.

CLI: `slam set-token` · `clear-token` · `repair-keychain-acl` · `run` · `version`. In the bot: `/help`.

## Status

Alpha. `swift build` and `swift test` are the gate: **121 tests / 22 suites** on the snapshot that opened this repository. Outgoing Telegram messages use HTML `parse_mode` (command transcripts in `<pre>`, hints in italics); the model does not author markup.

## Documentation

- [Landing page](https://valdagon.github.io/slam/)
- [Specification](docs/SPEC.md) · [Русский](docs/SPEC.ru.md) · [Srpski](docs/SPEC.sr.md)
- [Competitors and native practices](research/competitors.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE)
