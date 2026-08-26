# S.L.A.M

**Swift Light Agent for Mac** — nativni headless AI-agent za **macOS (Apple Silicon)**: Swift 6 demon, razgovor preko Telegrama, lokalni Ollama i `sandbox-exec` za komande modela.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-black.svg)](Package.swift)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg)](https://swift.org)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)

**Sajt:** [valdagon.github.io/slam](https://valdagon.github.io/slam/)

**Jezici:** [English](README.md) · [Русский](README.ru.md) · Srpski

> **Alfa (0.1.0).** Može da se koristi. Komande, obim peščanika i ključevi konfiguracije mogu da se promene pre 1.0. Ovo je lični demon, ne proizvod sa SLA.

## Prednosti

- **U potpunosti Swift 6.** SPM izvršni paket, jezički režim Swift 6, `-strict-concurrency=complete`. Deljivo mutabilno stanje živi u actor-ima ili je `Sendable`. Nije Electron, Node, ni Python-omotač.
- **Projektovan oko ograničenja macOS-a**, nije portovan sa Linuxa ili iz oblaka:
  - LaunchAgent sa `KeepAlive` / `RunAtLoad` (procesom upravlja launchd, ne večni `run` u Terminalu)
  - Token bota samo u **macOS Keychain** (`kSecClassGenericPassword`) — nikad git, `.env` ili `config.json`
  - Komande modela kroz `sandbox-exec` (Seatbelt / SBPL), ne Docker Desktop
  - QoS `.utility` / `.background` — mirovanje na E-jezgrima
  - Budžet u specifikaciji: **RAM ≤ 100 MB**, **CPU ≲ 1%** u mirovanju
  - Ollama `keep_alive: 0` u svakom zahtevu — VRAM se oslobađa posle odgovora
  - Asinhroni `URLSession` (long poll + NDJSON); bez busy-loop petlji

Zero-GUI: demon nema prozor. Upravljanje iz Telegrama (`/start`, `/help`, `/status`, `/model`, čet). Memorija — SQLite (GRDB, WAL, FTS5). Destruktivne komande traže dugme potvrde (human-in-the-loop).

## Poređenje sa ZeroClaw

[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) je jak Rust-agent (Apache-2.0): jedan binarni fajl, Telegram long-polling, pairing/allowlist, mnogo provajdera uključujući Ollama, široka višekanalnost. Ovaj projekat to ne zamenjuje.

| | **S.L.A.M** | **ZeroClaw** (javna dokumentacija, avg 2026) |
|---|---|---|
| Stek | Swift 6 + Apple framework-i + GRDB | Rust, jedan binarni fajl |
| Životni ciklus na macOS | User LaunchAgent (`KeepAlive`, `RunAtLoad`, `ProcessType=Background`) | Cross-platform demon (nije launchd-first) |
| Izolacija alata | `sandbox-exec` SBPL (`deny default`, bez mreže u detetu) | Pairing, allowlist, workspace; opciono `runtime.kind="docker"` |
| Tajne | Telegram token **samo** u Keychain-u | U ovoj klasi često config-fajl — za *ovaj* demon to je antipatern |
| Kanali u v1 | Samo Telegram | 15–30+ (Telegram, Discord, Slack, iMessage, …) |
| VRAM lokalnog modela | `keep_alive: 0` + idle-unloader | Ollama je podržan; politika VRAM-a je proizvodna |
| Mirovanje | Spec + sopstvena merenja (≤ 100 MB / ≲ 1%) | Vendorska tvrdnja reda nekoliko MB — tuđe brojeve ne preuzimamo |

Poštena razmena: ZeroClaw prednjači u kanalima, cron/SOP i multi-agentu. S.L.A.M je **nativni macOS** demon za Telegram + lokalni Ollama, sa tvrdim budžetom resursa i Seatbelt umesto Docker-a.

Izvori: [research/competitors.sr.md](research/competitors.sr.md).

## Ograničenje upisa u workspace — samo alfa

Danas je Seatbelt profil (FR-22) namerno uzak:

- **Čitanje:** sistemske putanje potrebne za exec + workspace (`working_dir`, podrazumevano `~/.local/share/slam/workspace`)
- **Upis:** samo `WORKING_DIR/tmp` (i `/dev/null`)
- **Mreža:** zabranjena unutar peščanika
- **Osetljiva stabla** (`~/.ssh`, `~/.aws`, Keychain, `~/Documents`) su eksplicitno zabranjena

To je **bezbednosni podrazumevani opseg alfe**, ne trajno ograničenje proizvoda. Kasnije verzije će ga proširiti i/ili učiniti podesivim. `write_file` i redirekcije van `tmp/` u ovom izdanju se odbijaju namerno.

## Instalacija kao servis (oko 10 minuta)

Potrebno: macOS Apple Silicon, Xcode / Swift 6.3+, [Ollama](https://ollama.com) sa modelom.

```bash
git clone https://github.com/ValDagon/slam.git
cd slam
./install.sh
```

Pravi release → `~/.local/bin/slam`, piše `~/Library/LaunchAgents/com.local.slam.plist`, bootstrap `gui/$(id -u)`, start pri prijavi. Traži BotFather token ako je Keychain prazan.

```bash
./install.sh stop | start | restart | status | logs | uninstall | purge
```

Ručni kickstart: `launchctl kickstart -k gui/$(id -u)/com.local.slam`.

Zatim:

```bash
ollama pull qwen2.5:7b
mkdir -p ~/.config/slam
```

Numerički Telegram ID ide u `~/.config/slam/config.json` (ispod). Prvi ID je vlasnik.

## Brzi start (bez LaunchAgent-a)

```bash
swift build && swift test
swift run slam set-token          # token @BotFather → Keychain
# config.json sa telegram_allowlist
ollama pull qwen2.5:7b
swift run slam run
```

## Konfiguracija i Keychain

`~/.config/slam/config.json` drži **samo nestajne** postavke. Obavezno: `telegram_allowlist`. Ostalo ima podrazumevane vrednosti.

| Ključ | Značenje (podrazumevano) |
|---|---|
| `telegram_allowlist` | Dozvoljeni Telegram ID-jevi (prvi = vlasnik) |
| `model` | `qwen2.5:7b` |
| `working_dir` | workspace peščanika |
| `max_context_messages` | `20` |
| `idle_unload_minutes` | `10` |
| `sandbox_enabled` | `true` |
| `command_timeout_seconds` | `30` |
| `confirmation_timeout_seconds` | `600` |
| `use_native_tools` | `true` (Ollama `write_file` / `run_shell`; fallback je fence `` ```run ``) |
| `ollama_url` / `system_prompt` / `context_budget_chars` / `storage_quota_bytes` / `destructive_patterns` | opciono |

**Token:** Keychain `service=com.local.slam`, `account=telegram-bot-token`. Nikad ga ne lepite u issues, README ili config.

| Putanja | Sadržaj |
|---|---|
| `~/.config/slam/config.json` | konfiguracija |
| Keychain `com.local.slam` / `telegram-bot-token` | token bota |
| `~/Library/LaunchAgents/com.local.slam.plist` | LaunchAgent |
| `~/.local/bin/slam` | release binarni fajl |
| `~/.local/share/slam/agent.sqlite*` | baza |
| `~/.local/state/slam/logs/` | logovi demona i launchd-a |

### Eksploatacija

- **Zdravlje:** `/status` u Telegramu (uptime, RSS/CPU, baza, peščanik)
- **Logovi:** `./install.sh logs` ili `~/.local/state/slam/logs/slam.log`
- **Promena tokena:** opozovi kod @BotFather → `./install.sh stop` → `set-token` → `./install.sh start`
- **Promena modela:** `/model <name>` ili config + restart
- **Jedna instanca:** drugi proces ne startuje; ponovljeni HTTP 409 znači drugi poller sa istim tokenom
- **Dijalog Keychain:** svaki `./install.sh` ad-hoc potpisuje novi binarni fajl. Skripta zove `repair-keychain-acl`; ako macOS pita — **Always Allow** jednom
- **Uklanjanje servisa:** `./install.sh uninstall` (zaustavlja LaunchAgent, briše plist i `~/.local/bin/slam`; podaci ostaju)
- **Čišćenje ove mašine:** `./install.sh purge` — plus config, SQLite/workspace, logovi, URLSession keš, crash-izveštaji i stavka u Keychain-u (`clear-token`). Git clone i Ollama se ne diraju. Token bota opozovite kod @BotFather ako više nije potreban.

CLI: `slam set-token` · `clear-token` · `repair-keychain-acl` · `run` · `version`. U botu: `/help`.

## Status

Alfa. Kapija: `swift build` i `swift test` — **121 test / 22 svite** na snimku sa kojeg je otvoren ovaj repozitorijum. Odlazne Telegram poruke koriste HTML `parse_mode` (ispis komandi u `<pre>`, saveti kurzivom); model ne piše markup.

## Dokumentacija

- [Landing](https://valdagon.github.io/slam/)
- [Specifikacija](docs/SPEC.sr.md) · [English](docs/SPEC.md) · [Русский](docs/SPEC.ru.md)
- [Konkurenti i nativne prakse](research/competitors.sr.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Changelog](CHANGELOG.md)

Prevodi vodiča: [CONTRIBUTING.sr.md](CONTRIBUTING.sr.md), [SECURITY.sr.md](SECURITY.sr.md). Kanon GitHub community fajlova je engleski.

## Licenca

[MIT](LICENSE)
