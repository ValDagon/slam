# Dnevnik izmena

Kanon: [CHANGELOG.md](CHANGELOG.md) (engleski, Keep a Changelog).

## [Unreleased]

Alfa na `main`. Upis peščanika samo u `WORKING_DIR/tmp` — konzervativni default, **nije** granica 1.0.

- Rebrand: proizvod **S.L.A.M** (Swift Light Agent for Mac). CLI i putanje na disku su `slam`. Repo [`ValDagon/slam`](https://github.com/ValDagon/slam), Pages [valdagon.github.io/slam](https://valdagon.github.io/slam/). `./install.sh` prebacuje stari `swift-agent`.
- `./install.sh purge` — potpuno brisanje sa mašine (servis, podaci, Keychain). `uninstall` ostavlja podatke.

## [0.1.0-alpha] — 2026-08-26

Prvi javni snimak: Swift 6 SPM, LaunchAgent, Telegram HTML, lokalni Ollama (`keep_alive: 0`, native tools), SQLite (GRDB), `sandbox-exec`, token samo u Keychain-u.
