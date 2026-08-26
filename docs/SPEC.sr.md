# Specifikacija · S.L.A.M

Nativni autonomni AI-agent za macOS (Apple Silicon). Status: **alfa (0.1.0)** — etape ispod su urađene; API i obim peščanika mogu da se promene pre 1.0.

**Prevodi:** [English](SPEC.md) · [Русский](SPEC.ru.md)

Ovo je produktna specifikacija (funkcionalni zahtevi, arhitektura, non-goals). Nije dnevnik sesija.

---

## 1. North-star

Jedan rezidentni macOS proces (Apple Silicon, klasa 16 GB), jeftin u mirovanju: RAM ≤ 100 MB, CPU ≲ 1% u čekanju, rad na E-jezgrima gde QoS dozvoljava. Upravljanje samo preko Telegrama. Inteligencija je lokalni Ollama (podrazumevano Qwen 2.5 7B). Memorija je SQLite. Komande modela idu samo kroz Seatbelt peščanik; destruktivni šabloni traže ljudsku potvrdu.

## 2. Platforma i budžet resursa

| Parametar | Zahtev | Provera |
|---|---|---|
| Platforma | macOS, Apple Silicon (M1+, 16 GB unified) | arm64 build |
| Oblik | SPM executable, bez GUI | `swift build` bez AppKit |
| RAM u mirovanju | ≤ 100 MB RSS | `/status` + Activity Monitor / `footprint` |
| CPU u mirovanju | ≲ 1% (blokada na I/O između long-poll) | uzorak od nekoliko minuta |
| Jezik | Swift 6, `-strict-concurrency=complete`, async/await, actor-i | `Package.swift`, zelen `swift build` |
| Zavisnosti | samo GRDB.swift; mreža / Keychain / procesi — nativni framework-i | `Package.resolved` |
| QoS | Long poll, JSON, SQLite, procesi → `.utility`; održavanje baze → `.background`; poruka korisnika → `.userInitiated` | pregled |

Tvrdnje konkurenata o RAM-u su vendorske. U ovu specifikaciju ulaze samo **naša** merenja.

## 3. Arhitektura

Šema: [SPEC.md](SPEC.md) §3 (isti mermaid).

| Modul | Tip | Odgovornost |
|---|---|---|
| `AgentActor` | actor | mašina stanja, red ažuriranja, rutiranje |
| `TelegramListener` | nonisolated service | petlja `getUpdates`, backoff, 409 |
| `TelegramPublisher` | nonisolated service | `sendMessage` / throttle `editMessageText` |
| `OllamaClient` | nonisolated service | `POST /api/chat`, NDJSON preko `URLSession.bytes.lines` |
| `DatabaseManager` | actor | GRDB `DatabasePool`, istorija, FTS5, kvote, offset |
| `ProcessRunner` | nonisolated service | `Foundation.Process` + `sandbox-exec`, HITL |
| `KeychainStore` | struct | SecItem add/update/read tokena |
| `MaintenanceLoop` | Task | sažimanje, checkpoint/vacuum |
| `DaemonMain` | entry | config, Keychain, single-instance, start petlji |

Invariant: deljivo mutabilno stanje samo u actor-ima; poruke su `Sendable`; servisi `nonisolated`; nema `@MainActor`.

## 4. Funkcionalni zahtevi

### 4.1 Životni ciklus

- **FR-1** LaunchAgent `~/Library/LaunchAgents/com.local.slam.plist`: `KeepAlive={SuccessfulExit:false}`, `ThrottleInterval≥10`, `RunAtLoad=true`, `ProcessType=Background`, logovi u `~/.local/state/slam/logs/`. Instalacija `launchctl bootstrap gui/$(id -u)` (`install.sh`). Bez ručnog fork-a.
- **FR-2** Single-instance: drugi proces izlazi sa jasnom greškom. HTTP 409 od Telegrama je „drugi poller“.
- **FR-3** Config bez tajni: `~/.config/slam/config.json`.

### 4.2 Telegram

- **FR-4** Samo nativni `URLSession`. Long polling `getUpdates`: `timeout=30`, `allowed_updates`, `offset` u SQLite.
- **FR-5** Na startu: `getWebhookInfo` → `deleteWebhook` ako je webhook aktivan.
- **FR-6** Backoff: start 2 s, plafon 300 s, ×2, **full jitter**.
- **FR-7** Allowlist Telegram ID-jeva. Prvi `/start` neznanca — ponuda pairing-a; vlasnik dodaje preko `/allow` ili config-a.
- **FR-8** Komande: `/start`, `/help`, `/status`, `/model <name>`, `/allow <id>`, `/deny <id>`. Ostali tekst je potez modela.
- **FR-9** Strimovanje jednom porukom, `editMessageText` sa throttle ~1.5–2 s, `sendChatAction(typing)` ~svakih 4 s, kursor `▍`.

### 4.3 Keychain

- **FR-10** Token na startu iz Keychain (`kSecClassGenericPassword`, service `com.local.slam`, account `telegram-bot-token`). Fajlovi / plist / env su zabranjeni.
- **FR-11** Add-or-update: `SecItemAdd` → pri duplikatu `SecItemUpdate`. CLI: `slam set-token`.

### 4.4 Ollama

- **FR-12** `POST http://localhost:11434/api/chat`, podrazumevani model `qwen2.5:7b`, `"stream": true`, `"keep_alive": 0` **u svakom zahtevu** (top-level).
- **FR-13** Tok: `URLSession.bytes(for:)` + NDJSON; HTTP 200 pre čitanja; otkazivanje — otkazivanjem Task-a.
- **FR-14** Kontekst: poslednjih N poruka + FTS5 isečci + sistemski prompt, truncate po budžetu karaktera.
- **FR-15** Idle-unloader: posle M minuta mirovanja prazan `messages:[]` + `keep_alive: 0`.
- **FR-16** Protokol `ModelProvider` iznad Ollama. U v1 jedna implementacija.

### 4.5 Baza

- **FR-17** GRDB `DatabasePool` (WAL), `DatabaseMigrator`.
- **FR-18** Tabele v1: `sessions`, `messages` (+ FTS5 unicode61), `kv`, `pending_confirmations`, `meta`.
- **FR-19** Kvota: min(10% slobodnog prostora volumena, 20 GB). Na 85% — pozadinsko sažimanje i `incremental_vacuum`.
- **FR-20** Jednom na sat (`.background`): `wal_checkpoint(TRUNCATE)`, `incremental_vacuum`, `PRAGMA optimize`.

### 4.6 Komande i peščanik

- **FR-21** Nativni Ollama tools (`write_file`, `run_shell`) i fallback `` ```run ``. Izvršenje: `Foundation.Process` + `/usr/bin/sandbox-exec`. Putanje `write_file` strogo unutar `WORKING_DIR/tmp`.
- **FR-22** SBPL sa `-D WORKING_DIR` / `-D WORKING_TMP`: `(deny default)`; čitanje — sistemske biblioteke + `WORKING_DIR`; **upis — samo `WORKING_DIR/tmp`**; `(deny network*)`; eksplicitni deny `~/.ssh`, `~/.aws`, `~/Library/Keychains`, `~/Documents`.

  **Ograničenje upisa je samo alfa.** Trenutni write-scope je konzervativni bezbednosni default 0.1.0, ne trajno ograničenje proizvoda. Kasnija izdanja će ga proširiti i/ili učiniti podesivim.

- **FR-23** HITL: destruktivni šabloni čekaju inline dugmad, timeout 10 minuta. stdout/stderr/kod — u bazu i čet.
- **FR-24** Smoke `sandbox-exec` na boot-u; pri neuspehu kanal komandi je ugašen, demon živi.

## 5. Nije u v1

- Druge mreže (Discord, WhatsApp, iMessage, …) — samo Telegram.
- Telegram webhook.
- Vektorske baze / embeddings — FTS5 je dovoljan.
- Korisnički cron/SOP — unutrašnji tikovi postoje, korisnički rasporedi su backlog.
- GUI, cloud provajderi modela.

## 6. Šta je preuzeto iz polja

| Ideja | Tipičan izvor | Kod nas |
|---|---|---|
| Long-poll 30 s + backoff + 409 | ZeroClaw Telegram kanal | FR-4 / FR-6 / FR-2 |
| Pairing / allowlist | ZeroClaw, OpenClaw | FR-7 |
| Strim izmenama jedne poruke | ZeroClaw (`editMessageText`) | FR-9 |
| Budžet konteksta | OpenClaw MEMORY.md | FR-14 |
| Idle istovar VRAM | higijena lokalnog GPU | FR-15 |
| Protokol provajdera | ZeroClaw traits | FR-16 |
| Sopstvena merenja footprint-a | lekcija PicoClaw membench | §2 |
| WAL higijena | praksa SQLite | FR-20 |

## 7. Etape (urađene u alfi)

| Etapa | Sadržaj | DoD |
|---|---|---|
| 1. Kostur | SPM, Keychain, long poll, allowlist | zelen `swift test` |
| 2. Model | Ollama strim, `keep_alive:0`, unloader | strim u čet; težine se istovaruju |
| 3. Skladište | GRDB, FTS5, kvote | istorija posle restarta |
| 4. Izvršenje | `sandbox-exec`, HITL | upis van tmp zabranjen |
| 5. Servis | `install.sh`, `/status`, README | LaunchAgent posle prijave; ≤ 10 min |
| 6. Provera | prolaz kroz ovu specifikaciju | `swift test` + živi LaunchAgent + Telegram/Ollama |

## 8. Rizici

| Rizik | Mitigacija |
|---|---|
| `sandbox-exec` je formalno deprecated | smoke FR-24 |
| Budžet 100 MB je tesan | rano merenje; jedan pool |
| Telegram rate limit | throttle FR-9 |
| Slab tool-call na 7B | fence + HITL |
| Dve instance | FR-2 + dijagnostika 409 |

## 9. Izvori

[research/competitors.sr.md](../research/competitors.sr.md).
