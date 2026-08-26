# Contributing

**Translations:** [Русский](CONTRIBUTING.ru.md) · [Srpski](CONTRIBUTING.sr.md)

Thanks for considering a patch. S.L.A.M is an **alpha** macOS daemon: keep the change small, keep `swift test` green, and do not add secrets.

## Development setup

- macOS on Apple Silicon, Xcode (full toolchain — the embedded `Testing` module is required)
- Swift 6.x (`// swift-tools-version:6.0` in `Package.swift`)
- Optional: [Ollama](https://ollama.com) for live model tests (unit tests stub the network)

```bash
swift build
swift test
```

Every pull request must keep **`swift build` and `swift test` green**. Language mode is Swift 6 with `-strict-concurrency=complete`: shared mutable state belongs in an `actor` or must be `Sendable`. Network I/O uses `URLSession` async APIs. No busy loops; blocking calls stay out of the daemon path (process execution is the exception).

Idle resource budget is part of the spec (RAM ≤ 100 MB, CPU ≲ 1%). Changes that touch networking, SQLite, or `Process` should not silently blow that envelope.

## What to work on

- Bugs and sandbox/HITL correctness
- Tests for a behavior you change
- Docs in **English, Russian, and Serbian** when you change user-facing README/SPEC text (see `README.md`, `README.ru.md`, `README.sr.md`)

Please do **not**:

- Commit `.env`, tokens, Keychain dumps, or real chat IDs
- Add a second SPM dependency without a strong case (the spec allows GRDB only)
- Expand sandbox write scope in a drive-by — the `WORKING_DIR/tmp` limit is an explicit **alpha** default; changing it needs a dedicated discussion

## Pull requests

1. Fork and branch from `main`.
2. Add or update tests.
3. Run `swift test`.
4. Fill in the pull request template.
5. Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Security issues: [SECURITY.md](SECURITY.md), not a public issue.

## License

By contributing you agree that your work is licensed under the [MIT License](LICENSE), same as the project.
