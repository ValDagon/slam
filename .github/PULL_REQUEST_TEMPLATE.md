## Summary

- What changed and why (1–3 bullets). Not a file list.

## Test plan

- [ ] `swift build` is green
- [ ] `swift test` is green
- [ ] No tokens, `.env`, or Keychain dumps in the diff
- [ ] User-facing docs updated in EN / RU / SR if README or SPEC text changed
- [ ] Sandbox write scope (`WORKING_DIR/tmp`) unchanged unless this PR is *about* that (alpha default)

## Notes

Swift 6 strict concurrency: shared mutable state in actors or `Sendable`. Resource budget still applies if you touched networking, SQLite, or `Process`.
