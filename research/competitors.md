# Competitors and native macOS practices

Public notes for S.L.A.M (snapshot **2026-08-25**). Star counts and competitor RAM figures are **as claimed by those projects or their marketing** on that date — not independent benchmarks.

**Translations:** [Русский](competitors.ru.md) · [Srpski](competitors.sr.md)

---

## 1. Comparison

| Criterion | ZeroClaw | OpenClaw | PicoClaw |
|---|---|---|---|
| Language | Rust, one binary | TypeScript / Node.js gateway | Go, one static binary |
| Repo (Aug 2026) | [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) · ~32.6k stars · Apache-2.0 | [openclaw/openclaw](https://github.com/openclaw/openclaw) · ~387k stars · license “Other” | [sipeed/picoclaw](https://github.com/sipeed/picoclaw) · MIT |
| Idle RAM (claimed) | `<5MB` (vendor `/usr/bin/time -l`) | `>1GB` appears in ZeroClaw’s comparison — treat as **vendor jab**, not a lab number | `<10MB` claimed |
| Telegram | Yes. Bot API long-polling (`getUpdates`, offset, timeout 30s, backoff, 409). Plus Discord/Slack/Matrix/Signal/iMessage/WhatsApp/Email/Webhook, 15–30+ channels | Yes. grammY; long polling default, webhook optional; DM pairing, allowlist | Yes. 16–18+ chats including Telegram |
| Scheduler | CLI cron + SOP engine (cron/MQTT/webhook, approval gates) | SQLite cron + heartbeat (~30 min) | Built-in task scheduler |
| Memory | Pluggable backend; SOP substrate | Markdown `MEMORY.md` / `USER.md` + daily files; truncate if MEMORY.md >20k | Local files + membench |
| Tools / sandbox | shell/browser/HTTP/MCP; pairing, allowlists, workspace scoping; optional `runtime.kind="docker"` | Skills/plugins; session isolation; pairing | tools, MCP, sub-agents |
| Model providers | ~20–22+ including **Ollama** | Many via model-providers config | 30+ unified interface |
| Worth copying | Long-poll + 409; trait-swappable providers; pairing; lean-runtime discipline | Heartbeat vs many timers; memory flush before compaction; context budget | Measure your own footprint; one binary |

ZeroClaw idle-RAM and OpenClaw `>1GB` are **not** copied into S.L.A.M’s spec. We publish our own idle budget (≤ 100 MB / ≲ 1%) and measurements.

## 2. Native practices used here

- **launchd:** user LaunchAgent, `KeepAlive={SuccessfulExit:false}`, `RunAtLoad`, `ThrottleInterval≥10`, `ProcessType=Background`, `launchctl bootstrap gui/$(id -u)`. launchd owns the process — no manual fork.
- **Seatbelt / `sandbox-exec`:** `(deny default)` + parameterized `-D WORKING_DIR` / `WORKING_TMP`. Write only `WORKING_DIR/tmp` in **alpha**. `sandbox-exec` is formally deprecated but still used in production CLI sandboxes (Chromium, others). Boot smoke is mandatory (FR-24). Docker Desktop as the sandbox is rejected for a light personal Mac daemon.
- **Keychain:** `kSecClassGenericPassword`, add-or-update, never token-in-config. That is the opposite of “put the bot token in `.env` / toml”.
- **URLSession.bytes:** NDJSON (Ollama) and long-poll without busy loops.
- **Telegram:** one poller per token; `deleteWebhook` before `getUpdates`; persist offset.
- **GRDB + WAL + FTS5 unicode61** + hourly checkpoint/vacuum/optimize.
- **Ollama:** `keep_alive` is top-level; send `0` on every request; idle unloader with empty `messages`.
- **QoS:** `.utility` for the daemon loop, `.background` for DB maintenance (E-cores), `.userInitiated` for a user message.
- **Swift 6 complete concurrency:** actors for shared mutable state; `Sendable` messages; no `@MainActor`.

## 3. Takeaways for this daemon

1. Telegram is a channel, not the core — but v1 is Telegram-only on purpose.
2. Rust/Go proved a few-MB class; Swift 6 can sit in a **tens-of-MB** class if we stay native and measure.
3. Gold-standard Telegram loop: timeout 30, offset, backoff, 409 as second instance, allowlist before the model.
4. Do not hold memory only in RAM; SQLite is source of truth.
5. Tool sandbox: deny-default SBPL, write tmp-only in alpha (expand later).
6. Secrets: Keychain only.
7. Explicit `keep_alive: 0` + idle unloader for laptop VRAM.
8. `ProcessType=Background` aligns launchd with GCD QoS.
9. WAL hygiene on a timer; full jitter on reconnects; single-instance lock.
10. Never paste competitor vendor RAM into our README as fact.

## 4. Sources

1. https://zeroclaw.space/
2. https://zeroclaw.org/
3. https://github.com/zeroclaw-labs/zeroclaw
4. https://github.com/zeroclaw-labs/zeroclaw/releases
5. https://mintlify.wiki/zeroclaw-labs/zeroclaw/api/channels/telegram
6. https://docs.openclaw.ai/channels/telegram/
7. https://docs.openclaw.ai/automation/cron-jobs · https://docs.openclaw.ai/gateway/heartbeat
8. https://docs.openclaw.ai/concepts/memory
9. https://github.com/openclaw/openclaw
10. https://github.com/sipeed/picoclaw · https://picoclaw.io/
11. https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html
12. https://www.launchd.info/
13. https://chromium.googlesource.com/chromium/src/+/main/sandbox/mac/README.md
14. https://core.telegram.org/bots/api#getupdates
15. https://github.com/groue/GRDB.swift
16. https://github.com/ollama/ollama/blob/main/docs/api.md · https://github.com/ollama/ollama/pull/2146
17. https://developer.apple.com/news/?id=vk3m204o (QoS / Apple Silicon)
