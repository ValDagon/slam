# Konkurenti i nativne prakse macOS

Javne beleške za S.L.A.M (presek **2026-08-25**). Broj zvezdica i RAM konkurenata su **kako ti projekti tvrde** na taj datum, ne nezavisni benchmark.

**Prevodi:** [English](competitors.md) · [Русский](competitors.ru.md)

---

## 1. Poređenje

| Kriterijum | ZeroClaw | OpenClaw | PicoClaw |
|---|---|---|---|
| Jezik | Rust, jedan binarni fajl | TypeScript / Node.js gateway | Go, jedan statički binarni fajl |
| Repo (avg 2026) | [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) · ~32.6k stars · Apache-2.0 | [openclaw/openclaw](https://github.com/openclaw/openclaw) · ~387k stars · licenca „Other“ | [sipeed/picoclaw](https://github.com/sipeed/picoclaw) · MIT |
| RAM u mirovanju (tvrdnja) | `<5MB` (vendorski `/usr/bin/time -l`) | `>1GB` u ZeroClaw tabeli — tretirati kao **vendorski ubod**, ne laboratorijski broj | tvrdnja `<10MB` |
| Telegram | Da. Bot API long-polling (`getUpdates`, offset, timeout 30s, backoff, 409). Plus Discord/Slack/Matrix/…, 15–30+ kanala | Da. grammY; long polling podrazumevano; pairing, allowlist | Da. 16–18+ četova uključujući Telegram |
| Raspoređivač | CLI cron + SOP | cron u SQLite + heartbeat | Ugrađeni scheduler |
| Memorija | Priključivi backend | Markdown `MEMORY.md` / `USER.md`; truncate preko 20k | Lokalni fajlovi + membench |
| Alati / peščanik | shell/HTTP/MCP; pairing, allowlist, workspace; opciono `runtime.kind="docker"` | Skills/plugins; izolacija sesija | tools, MCP, sub-agents |
| Provajderi | ~20–22+ uključujući **Ollama** | Mnogo preko config-a | 30+ unified interface |
| Šta preuzeti | Long-poll + 409; zamenjivi provajderi; pairing; disciplina veličine | Heartbeat umesto hrpe tajmera; flush memorije; budžet konteksta | Sopstvena merenja footprint-a; jedan binarni fajl |

Brojevi idle-RAM ZeroClaw i `>1GB` za OpenClaw **ne** ulaze u specifikaciju S.L.A.M. Objavljujemo sopstveni budžet (≤ 100 MB / ≲ 1%) i sopstvena merenja.

## 2. Nativne prakse koje se ovde koriste

- **launchd:** user LaunchAgent, `KeepAlive={SuccessfulExit:false}`, `RunAtLoad`, `ThrottleInterval≥10`, `ProcessType=Background`, `launchctl bootstrap gui/$(id -u)`.
- **Seatbelt / `sandbox-exec`:** `(deny default)` + `-D WORKING_DIR` / `WORKING_TMP`. Upis samo u `WORKING_DIR/tmp` u **alfi**. `sandbox-exec` je formalno deprecated. Docker Desktop kao peščanik za laki lični demon je odbačen.
- **Keychain:** GenericPassword, add-or-update, token nije u config-u ni u `.env`.
- **URLSession.bytes:** NDJSON i long-poll bez busy-loop.
- **Telegram:** jedan poller po tokenu; `deleteWebhook` pre `getUpdates`; offset u bazi.
- **GRDB + WAL + FTS5 unicode61** i časovni checkpoint/vacuum/optimize.
- **Ollama:** `keep_alive` top-level; `0` u svakom zahtevu; idle-unloader sa praznim `messages`.
- **QoS:** `.utility` petlja demona, `.background` održavanje baze (E-jezgra), `.userInitiated` poruka korisnika.
- **Swift 6 complete concurrency:** actor-i, `Sendable`, bez `@MainActor`.

## 3. Zaključci za ovaj demon

1. Telegram je kanal, ne jezgro; u v1 je namerno jedini.
2. Rust/Go su dokazali klasu nekoliko MB; Swift 6 može da živi u **desetinama MB** ako ostane nativan i meri.
3. Zlatni Telegram ciklus: timeout 30, offset, backoff, 409 kao druga instanca, allowlist pre modela.
4. Memorija nije samo u RAM-u; SQLite je izvor istine.
5. Peščanik: deny-default SBPL, upis tmp-only u alfi (kasnije širimo).
6. Tajne samo u Keychain-u.
7. Eksplicitni `keep_alive: 0` + idle-unloader za VRAM laptopa.
8. `ProcessType=Background` usklađuje launchd i GCD QoS.
9. WAL higijena po tajmeru; full jitter na reconnect; single-instance lock.
10. Vendorski RAM konkurenata ne stavljati u README kao činjenicu.

## 4. Izvori

Isti URL-ovi kao u [competitors.md](competitors.md).
