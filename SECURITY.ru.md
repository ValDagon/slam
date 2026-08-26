# Политика безопасности

Канон: [SECURITY.md](SECURITY.md) (английский).

## Поддерживаемые версии

S.L.A.M в статусе **альфа**. Исправления безопасности идут в `main`. Веток LTS пока нет.

## Как сообщить об уязвимости

**Не открывайте** публичный issue про дыры, утечки токена или обход песочницы.

1. [GitHub Private Vulnerability Reporting](https://github.com/ValDagon/slam/security/advisories/new), если на репозитории включено.
2. Иначе напишите мейнтейнеру в GitHub: [@ValDagon](https://github.com/ValDagon).

Укажите: версию macOS, версию S.L.A.M (`slam version`), шаги, ожидаемое/фактическое поведение, минимальное воспроизведение. **Никогда не вставляйте токен Telegram-бота, дамп Keychain или `.env`.** Если токен мог утечь — сначала отзовите его у [@BotFather](https://t.me/BotFather).

Ответим как можно скорее; предпочтителен согласованный disclosure.

## Что проект уже предполагает

- Токен бота живёт **только** в macOS Keychain (`service=com.local.slam`, `account=telegram-bot-token`). Его не должно быть в git, `config.json`, plist LaunchAgent, логах и issues.
- Команды модели идут через `sandbox-exec` (Seatbelt). В альфе запись только в `WORKING_DIR/tmp` — это безопасный дефолт, не обещание, что песочница удержит целеустремлённого локального атакующего.
- Доступ к боту — allowlist Telegram ID. Не публикуйте свои ID, если считаете их чувствительными.

См. [README.ru.md](README.ru.md) и [docs/SPEC.ru.md](docs/SPEC.ru.md) FR-10, FR-22, FR-23.
