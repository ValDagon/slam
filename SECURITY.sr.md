# Politika bezbednosti

Kanon: [SECURITY.md](SECURITY.md) (engleski).

## Podržane verzije

S.L.A.M je **alfa**. Bezbednosni fiksevi idu na `main`. LTS grana još nema.

## Prijava ranjivosti

**Ne otvarajte** javni issue za rupe, curenje tokena ili obilazak peščanika.

1. [GitHub Private Vulnerability Reporting](https://github.com/ValDagon/slam/security/advisories/new) ako je uključeno na repozitorijumu.
2. Inače kontaktirajte održavaoca na GitHub-u: [@ValDagon](https://github.com/ValDagon).

Uključite: verziju macOS, verziju S.L.A.M (`slam version`), korake, očekivano/stvarno ponašanje, minimalnu reprodukciju. **Nikad ne lepite Telegram bot token, Keychain dump ili `.env`.** Ako je token mogao da procuri — prvo ga opozovite kod [@BotFather](https://t.me/BotFather).

Odgovorićemo čim bude praktično; preferiramo usklađeno objavljivanje.

## Šta projekat već pretpostavlja

- Token bota živi **samo** u macOS Keychain (`service=com.local.slam`, `account=telegram-bot-token`). Ne sme da se nađe u git-u, `config.json`, LaunchAgent plist-u, logovima ili issues.
- Komande modela idu kroz `sandbox-exec` (Seatbelt). U alfi je upis samo u `WORKING_DIR/tmp` — to je bezbednosni podrazumevani opseg, ne obećanje da peščanik drži odlučnog lokalnog napadača.
- Pristup botu je allowlist Telegram ID-jeva. Ne objavljujte svoje ID-jeve ako ih smatrate osetljivim.

Vidi [README.sr.md](README.sr.md) i [docs/SPEC.sr.md](docs/SPEC.sr.md) FR-10, FR-22, FR-23.
