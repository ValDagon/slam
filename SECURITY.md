# Security Policy

**Translations:** [Русский](SECURITY.ru.md) · [Srpski](SECURITY.sr.md)

## Supported versions

S.L.A.M is **alpha**. Security fixes land on `main`. There are no long-term support branches yet.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems, leaked tokens, or sandbox escapes.

1. Use [GitHub Private Vulnerability Reporting](https://github.com/ValDagon/slam/security/advisories/new) if it is enabled on this repository.
2. Otherwise contact the maintainer privately via GitHub: [@ValDagon](https://github.com/ValDagon).

Include: macOS version, S.L.A.M version (`slam version`), what you did, what happened, and a minimal reproduction. **Never paste a Telegram bot token, Keychain dump, or `.env` file.** If a token may have leaked, revoke it at [@BotFather](https://t.me/BotFather) first, then report.

We will acknowledge reports as soon as practical and prefer coordinated disclosure.

## What this project already assumes

- The Telegram bot token lives **only** in macOS Keychain (`service=com.local.slam`, `account=telegram-bot-token`). It must not appear in git, `config.json`, LaunchAgent plists, logs, or issues.
- Model-issued commands run under `sandbox-exec` (Seatbelt). Alpha write scope is `WORKING_DIR/tmp` only; that is a safety default, not an invitation to treat the sandbox as a hard security boundary against a determined local attacker.
- Access to the bot is an allowlist of Telegram user IDs. Do not publish your allowlist IDs if you consider them sensitive.

See [README.md](README.md) (Keychain and workspace sections) and [docs/SPEC.md](docs/SPEC.md) FR-10, FR-22, FR-23.
