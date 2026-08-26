(() => {
  "use strict";

  const INSTALL = `git clone https://github.com/ValDagon/slam.git
cd slam
./install.sh`;

  const COPY_LABEL = { en: "Copy", ru: "Копировать", sr: "Kopiraj" };
  const COPIED_LABEL = { en: "Copied", ru: "Скопировано", sr: "Kopirano" };
  const MENU_OPEN = { en: "Menu", ru: "Меню", sr: "Meni" };
  const MENU_CLOSE = { en: "Close", ru: "Закрыть", sr: "Zatvori" };

  const strings = {
    en: {
      skip: "Skip to content",
      navHow: "How it works",
      navSecurity: "Security",
      navFaq: "FAQ",
      navDocs: "Docs",
      navGitHub: "GitHub",
      badge: "Open source · 0.1.0-alpha",
      heroTitle: "The macOS agent\nyou actually own.",
      heroAccent: "you actually own.",
      lede: "A Swift 6 LaunchAgent on Apple Silicon. You talk over Telegram; inference stays on local Ollama. The bot token lives in Keychain. Model-issued commands run under Seatbelt. No cloud seat, no subscription.",
      star: "Star on GitHub",
      termCaption: "LaunchAgent transcript",
      termBody: `$ ./install.sh
release → ~/.local/bin/slam
LaunchAgent gui/$(id -u)/com.local.slam
$ launchctl print gui/$(id -u)/com.local.slam
state = running
$  /status
rss ~18 MB · cpu ≲ 1% · sandbox ok`,
      quoteGray: "Most AI assistants are a seat you rent on someone else’s machine.",
      quoteInk: "S.L.A.M is a LaunchAgent you own on yours.",
      m1n: "1",
      m1k: "Native binary",
      m1d: "Swift 6 SPM executable. No Node, no JVM, no Python environment to install.",
      m2n: "~18 MB",
      m2k: "Measured idle RSS",
      m2d: "Spec budget is RAM ≤ 100 MB and CPU ≲ 1% while waiting on long-poll.",
      m3n: "121",
      m3k: "Tests",
      m3d: "22 suites on the public snapshot. swift test is the merge gate.",
      m4n: "1",
      m4k: "Channel (alpha)",
      m4d: "Telegram only, on purpose. Local Ollama is the model path in this release.",
      footMetrics: "VRAM is released after each answer (Ollama keep_alive: 0). Idle work uses QoS .utility / .background so it can sit on E-cores.",
      howTitle: "Running after a clone",
      howLede: "There is no curl-to-a-random-domain installer. Clone the public repo, run ./install.sh, pull a local model, then talk in Telegram.",
      s1t: "Clone the repo",
      s1d: "Source of truth is GitHub. You build on your Mac with the Swift toolchain you already trust.",
      s1c: "git clone https://github.com/ValDagon/slam.git",
      s2t: "Install the service",
      s2d: "Release binary to ~/.local/bin, LaunchAgent plist, bootstrap gui/$(id -u). Prompts for a BotFather token if Keychain is empty.",
      s2c: "./install.sh",
      s3t: "Pull a local model",
      s3d: "Default in docs is qwen2.5:7b. Inference is on your machine; the daemon does not ship weights.",
      s3c: "ollama pull qwen2.5:7b",
      s4t: "Talk in Telegram",
      s4d: "Zero GUI. /status reports RSS, CPU, DB, and sandbox. Chat is a model turn; destructive shell waits for a button.",
      s4c: "/status",
      secTitle: "Shell access you can contain",
      secLede: "The analog of a “receipt” here is the Seatbelt profile the child actually runs under — deny-default, write-scoped, no network, secrets not in files.",
      recK: "Seatbelt profile",
      recV: "SBPL · sandbox-exec",
      r1a: "deny",
      r1b: "default",
      r2a: "write",
      r2b: "WORKING_DIR/tmp only  (alpha)",
      r3a: "network",
      r3b: "deny  (sandboxed child)",
      r4a: "sensitive",
      r4b: "~/.ssh · ~/.aws · Keychains · ~/Documents",
      r5a: "token",
      r5b: "Keychain — never .env or config.json",
      r6a: "hitl",
      r6b: "destructive patterns wait for your button",
      recCap: "The model never sees the Keychain item. Alpha write scope is a safety default, not a 1.0 product limit.",
      f1t: "Supervised commands",
      f1d: "Destructive patterns from config wait on Telegram inline buttons (10-minute timeout, then deny).",
      f2t: "OS sandbox",
      f2d: "sandbox-exec Seatbelt, not Docker Desktop. Boot smoke (FR-24): if the profile fails, the run channel stays off and the daemon stays up.",
      f3t: "Workspace policy",
      f3d: "Read: system paths needed to exec plus the workspace. Write: WORKING_DIR/tmp. Sensitive trees are explicitly denied.",
      f4t: "Keychain, not files",
      f4d: "Bot token is kSecClassGenericPassword (service com.local.slam). It must not appear in git, plist, logs, or issues.",
      prodTitle: "Built around macOS",
      prodLede: "Killer features are constraints, not a pitch deck: Swift 6, launchd, Keychain, Seatbelt, QoS, idle budget, keep_alive: 0.",
      p1t: "Fully Swift 6",
      p1d: "SPM executable, language mode Swift 6, -strict-concurrency=complete. Shared mutable state lives in actors or is Sendable.",
      p2t: "LaunchAgent lifecycle",
      p2d: "KeepAlive, RunAtLoad, ProcessType=Background. launchd owns the process; you do not leave a forever-run in Terminal.",
      p3t: "Keychain secrets",
      p3d: "The Telegram token is not in .env. config.json holds non-secrets only (allowlist, model, paths).",
      p4t: "Seatbelt isolation",
      p4d: "Model-issued shell is Foundation.Process + sandbox-exec. Native Ollama tools write_file / run_shell, with a fence fallback.",
      p5t: "E-core idle",
      p5d: "QoS .utility / .background for waiting work. Spec: RAM ≤ 100 MB idle, CPU ≲ 1% between long-polls.",
      p6t: "VRAM hygiene",
      p6d: "Ollama keep_alive: 0 on every request, plus an idle unloader, so laptop GPU memory is released after each answer.",
      useTitle: "What you can do today",
      useLede: "Alpha: a personal Telegram daemon on one Mac. Not a multi-channel platform. Honest scope beats a fake catalog.",
      u1t: "Personal assistant",
      u1d: "Chat from Telegram. Memory is SQLite (GRDB, WAL, FTS5) on disk, not a rented cloud notebook.",
      u2t: "Sandboxed shell",
      u2d: "Ask for disk usage or a workspace listing. The child has no network; writes outside tmp are denied.",
      u3t: "Files in tmp",
      u3d: "write_file and redirects may land only in WORKING_DIR/tmp in this release. That limit will widen.",
      u4t: "HITL confirmations",
      u4d: "rm-class patterns do not run until you tap the inline button. stdout/stderr come back into the chat.",
      u5t: "Health in chat",
      u5d: "/status reports uptime, RSS, CPU, database, and sandbox. Logs stay under ~/.local/state/slam/logs/.",
      u6t: "Local model",
      u6d: "Default docs model is qwen2.5:7b via localhost Ollama. Other local names work through /model.",
      vsTitle: "Fair vs ZeroClaw",
      vsLede: "ZeroClaw is a strong Rust agent with many channels. This project does not try to replace that. Native Swift/macOS-first is the point.",
      vsCol: "S.L.A.M",
      vsZ: "ZeroClaw (public docs, Aug 2026)",
      vsR1a: "Stack",
      vsR1b: "Swift 6 + Apple frameworks + GRDB",
      vsR1c: "Rust, one binary",
      vsR2a: "macOS lifecycle",
      vsR2b: "User LaunchAgent (KeepAlive, RunAtLoad)",
      vsR2c: "Cross-platform daemon (not launchd-first)",
      vsR3a: "Tool isolation",
      vsR3b: "sandbox-exec SBPL, no child network",
      vsR3c: "Pairing, allowlists; optional Docker runtime",
      vsR4a: "Secrets",
      vsR4b: "Telegram token only in Keychain",
      vsR4c: "Typical of the class: config-file secrets",
      vsR5a: "Channels in v1",
      vsR5b: "Telegram only",
      vsR5c: "15–30+ networks",
      vsNote: "Workspace writes are alpha-only: today write only WORKING_DIR/tmp. Later versions will widen and/or make it configurable.",
      mapTitle: "Roadmap, without fake dates",
      mapLede: "Things ship when they are ready. No copied competitor version numbers.",
      rA: "Shipped",
      rAt: "Alpha daemon",
      rAd: "LaunchAgent, Telegram long-poll, local Ollama, SQLite memory, Seatbelt, Keychain, HITL, 121 tests.",
      rB: "Next",
      rBt: "Wider workspace",
      rBd: "Lift the tmp-only write default. Keep deny-default and sensitive-path denies until that work lands.",
      rC: "Later",
      rCt: "Toward 1.0",
      rCd: "Stable config/security contract, configurable sandbox. Extra chat networks stay a non-goal until we choose otherwise.",
      faqTitle: "Questions, answered",
      q1: "What is S.L.A.M?",
      a1: "S.L.A.M (Swift Light Agent for Mac) is a native headless AI agent for macOS (Apple Silicon): a Swift 6 daemon you talk to over Telegram, with local Ollama for inference and sandbox-exec for model-issued commands. Zero GUI — launchd owns the process.",
      q2: "Is it free?",
      a2: "Yes. MIT license. No subscription and no hosted seat. You pay only for hardware and whatever local model you run.",
      q3: "How lightweight is it?",
      a3: "Spec idle budget is RAM ≤ 100 MB and CPU ≲ 1%. Measured idle RSS on the development Mac was around 18 MB. 121 tests / 22 suites gate the public snapshot.",
      q4: "Does my data leave the machine?",
      a4: "The daemon and Ollama run locally. Telegram is the control channel, so messages you send go to Telegram’s API — that is inherent to a Telegram bot. There is no S.L.A.M cloud in the middle. The bot token never sits in a file.",
      q5: "How is it secured?",
      a5: "Token in Keychain. Allowlist of Telegram user IDs. Seatbelt deny-default with tmp-only writes in alpha. Destructive commands need a human button. sandbox-exec is probed at boot.",
      q6: "What can it connect to?",
      a6: "Telegram only in this release. Local Ollama on localhost. Extra networks (Discord, Slack, iMessage, …) are explicit non-goals for v1.",
      closeTitle: "Run it on your Mac.",
      closeLede: "Clone, ./install.sh, pull a model, open Telegram. Star the repo if the macOS-native bet is useful.",
      docs: "Read the spec",
      footName: "S.L.A.M 0.1.0-alpha",
      footTag: "You own the daemon. You own the data. The token stays in Keychain.",
      footMeta: "MIT · 2026 · Apple Silicon macOS",
    },
    ru: {
      skip: "К содержанию",
      navHow: "Как запустить",
      navSecurity: "Безопасность",
      navFaq: "FAQ",
      navDocs: "Документация",
      navGitHub: "GitHub",
      badge: "Открытый код · 0.1.0-alpha",
      heroTitle: "Агент для macOS,\nкоторым владеете вы.",
      heroAccent: "которым владеете вы.",
      lede: "LaunchAgent на Swift 6 для Apple Silicon. Общение — Telegram, вывод — локальная Ollama. Токен бота в Keychain. Команды модели — под Seatbelt. Без облачной подписки.",
      star: "Звезда на GitHub",
      termCaption: "Транскрипт LaunchAgent",
      termBody: `$ ./install.sh
release → ~/.local/bin/slam
LaunchAgent gui/$(id -u)/com.local.slam
$ launchctl print gui/$(id -u)/com.local.slam
state = running
$  /status
rss ~18 MB · cpu ≲ 1% · sandbox ok`,
      quoteGray: "Большинство ИИ-ассистентов — арендованное место на чужой машине.",
      quoteInk: "S.L.A.M — LaunchAgent, который принадлежит вам на вашей.",
      m1n: "1",
      m1k: "Нативный бинарник",
      m1d: "Исполняемый SPM на Swift 6. Не нужно ставить Node, JVM или Python-окружение.",
      m2n: "~18 МБ",
      m2k: "RSS в простое (замер)",
      m2d: "Бюджет спецификации: RAM ≤ 100 МБ и CPU ≲ 1% в ожидании long-poll.",
      m3n: "121",
      m3k: "Тестов",
      m3d: "22 сюиты на публичном снимке. Слияние — только при зелёном swift test.",
      m4n: "1",
      m4k: "Канал (альфа)",
      m4d: "Только Telegram — сознательно. Модель в этом релизе — локальная Ollama.",
      footMetrics: "VRAM снимается после каждого ответа (Ollama keep_alive: 0). Простой идёт с QoS .utility / .background — на E-ядрах.",
      howTitle: "Запуск после clone",
      howLede: "Нет установщика curl с чужого домена. Клонируйте публичный репозиторий, выполните ./install.sh, скачайте локальную модель, пишите в Telegram.",
      s1t: "Клонировать репозиторий",
      s1d: "Источник — GitHub. Собираете на своём Mac тем Swift, которому уже доверяете.",
      s1c: "git clone https://github.com/ValDagon/slam.git",
      s2t: "Поставить сервис",
      s2d: "Release-бинарник в ~/.local/bin, plist LaunchAgent, bootstrap gui/$(id -u). Спросит токен BotFather, если Keychain пуст.",
      s2c: "./install.sh",
      s3t: "Скачать локальную модель",
      s3d: "В документации по умолчанию qwen2.5:7b. Веса демон не возит — вывод у вас на машине.",
      s3c: "ollama pull qwen2.5:7b",
      s4t: "Писать в Telegram",
      s4d: "Окна нет. /status показывает RSS, CPU, БД и песочницу. Чат — ход модели; деструктивный шелл ждёт кнопку.",
      s4c: "/status",
      secTitle: "Доступ к шеллу, который можно удержать",
      secLede: "Наш аналог «чека» — профиль Seatbelt, под которым реально крутится потомок: deny-default, узкая запись, без сети, секреты не в файлах.",
      recK: "Профиль Seatbelt",
      recV: "SBPL · sandbox-exec",
      r1a: "deny",
      r1b: "default",
      r2a: "write",
      r2b: "только WORKING_DIR/tmp  (альфа)",
      r3a: "network",
      r3b: "deny  (песочный потомок)",
      r4a: "sensitive",
      r4b: "~/.ssh · ~/.aws · Keychains · ~/Documents",
      r5a: "token",
      r5b: "Keychain — никогда не .env и не config.json",
      r6a: "hitl",
      r6b: "деструктивные шаблоны ждут вашу кнопку",
      recCap: "Модель не видит запись Keychain. Узкая запись в альфе — страховка, не потолок продукта 1.0.",
      f1t: "Команды под присмотром",
      f1d: "Деструктивные шаблоны из конфига ждут inline-кнопку в Telegram (таймаут 10 минут, затем отказ).",
      f2t: "Песочница ОС",
      f2d: "sandbox-exec Seatbelt, не Docker Desktop. Дымовой тест на буте (FR-24): если профиль мёртв, канал команд выключен, демон жив.",
      f3t: "Политика workspace",
      f3d: "Чтение: системные пути для exec плюс workspace. Запись: WORKING_DIR/tmp. Чувствительные деревья явно запрещены.",
      f4t: "Keychain, не файлы",
      f4d: "Токен бота — kSecClassGenericPassword (service com.local.slam). Его не должно быть в git, plist, логах и issues.",
      prodTitle: "Спроектирован под macOS",
      prodLede: "Сильные стороны — это ограничения, не слайды: Swift 6, launchd, Keychain, Seatbelt, QoS, бюджет простоя, keep_alive: 0.",
      p1t: "Полностью Swift 6",
      p1d: "SPM-исполняемый файл, режим языка Swift 6, -strict-concurrency=complete. Разделяемое состояние — в акторах или Sendable.",
      p2t: "Жизненный цикл LaunchAgent",
      p2d: "KeepAlive, RunAtLoad, ProcessType=Background. Процессом владеет launchd, а не вечный run в Терминале.",
      p3t: "Секреты в Keychain",
      p3d: "Токен Telegram не в .env. В config.json только не-секреты (allowlist, модель, пути).",
      p4t: "Изоляция Seatbelt",
      p4d: "Шелл модели — Foundation.Process + sandbox-exec. Нативные tools Ollama write_file / run_shell, плюс запасной fence.",
      p5t: "Простой на E-ядрах",
      p5d: "QoS .utility / .background для ожидания. Спека: RAM ≤ 100 МБ в простое, CPU ≲ 1% между long-poll.",
      p6t: "Гигиена VRAM",
      p6d: "Ollama keep_alive: 0 в каждом запросе и idle-unloader — видеопамять ноутбука отпускается после ответа.",
      useTitle: "Что можно сегодня",
      useLede: "Альфа: личный демон Telegram на одном Mac. Не многоканальная платформа. Честный объём лучше фальшивого каталога.",
      u1t: "Личный ассистент",
      u1d: "Чат из Telegram. Память — SQLite (GRDB, WAL, FTS5) на диске, не арендованный облачный блокнот.",
      u2t: "Шелл в песочнице",
      u2d: "Спросите место на диске или список workspace. У потомка нет сети; запись вне tmp запрещена.",
      u3t: "Файлы в tmp",
      u3d: "write_file и редиректы в этом релизе только в WORKING_DIR/tmp. Позже рамку расширим.",
      u4t: "Подтверждение HITL",
      u4d: "Шаблоны класса rm не выполняются, пока не нажмёте кнопку. stdout/stderr возвращаются в чат.",
      u5t: "Здоровье в чате",
      u5d: "/status — uptime, RSS, CPU, БД, песочница. Логи в ~/.local/state/slam/logs/.",
      u6t: "Локальная модель",
      u6d: "В документации по умолчанию qwen2.5:7b через localhost Ollama. Другие локальные имена — через /model.",
      vsTitle: "Честно против ZeroClaw",
      vsLede: "ZeroClaw — сильный Rust-агент с множеством каналов. Этот проект его не «заменяет». Ставка — нативный Swift и macOS.",
      vsCol: "S.L.A.M",
      vsZ: "ZeroClaw (публичные материалы, авг 2026)",
      vsR1a: "Стек",
      vsR1b: "Swift 6 + фреймворки Apple + GRDB",
      vsR1c: "Rust, один бинарник",
      vsR2a: "Жизненный цикл macOS",
      vsR2b: "User LaunchAgent (KeepAlive, RunAtLoad)",
      vsR2c: "Кроссплатформенный демон (не launchd-first)",
      vsR3a: "Изоляция инструментов",
      vsR3b: "sandbox-exec SBPL, без сети у потомка",
      vsR3c: "Pairing, allowlist; опционально Docker",
      vsR4a: "Секреты",
      vsR4b: "Токен Telegram только в Keychain",
      vsR4c: "В этом классе часто секреты в конфиге",
      vsR5a: "Каналы в v1",
      vsR5b: "Только Telegram",
      vsR5c: "15–30+ сетей",
      vsNote: "Запись в workspace — только альфа: сегодня пишем лишь в WORKING_DIR/tmp. Позже расширим и/или сделаем настраиваемым.",
      mapTitle: "Дорожная карта без выдуманных дат",
      mapLede: "Шипаем, когда готово. Номера версий конкурента не копируем.",
      rA: "Сделано",
      rAt: "Альфа-демон",
      rAd: "LaunchAgent, long-poll Telegram, локальная Ollama, SQLite, Seatbelt, Keychain, HITL, 121 тест.",
      rB: "Дальше",
      rBt: "Шире workspace",
      rBd: "Снять запрет «писать только в tmp». deny-default и запрет чувствительных путей остаются, пока эта работа не приземлится.",
      rC: "Позже",
      rCt: "К 1.0",
      rCd: "Стабильный контракт конфига и безопасности, настраиваемая песочница. Лишние мессенджеры — non-goal, пока не решим иначе.",
      faqTitle: "Вопросы и ответы",
      q1: "Что такое S.L.A.M?",
      a1: "S.L.A.M (Swift Light Agent for Mac) — нативный headless ИИ-агент для macOS (Apple Silicon): демон на Swift 6, общение через Telegram, локальная Ollama и sandbox-exec для команд модели. Окна нет — процессом владеет launchd.",
      q2: "Это бесплатно?",
      a2: "Да. Лицензия MIT. Нет подписки и нет облачного места. Платите только за железо и ту локальную модель, которую запускаете.",
      q3: "Насколько он лёгкий?",
      a3: "Бюджет спеки в простое: RAM ≤ 100 МБ и CPU ≲ 1%. Замеренный idle RSS на машине разработки — около 18 МБ. Публичный снимок закрывают 121 тест / 22 сюиты.",
      q4: "Данные уходят с машины?",
      a4: "Демон и Ollama работают локально. Telegram — канал управления, поэтому ваши сообщения идут в API Telegram — это свойство бота. Облака S.L.A.M посередине нет. Токен бота не лежит в файле.",
      q5: "Как это защищено?",
      a5: "Токен в Keychain. Allowlist Telegram ID. Seatbelt deny-default, в альфе запись только в tmp. Деструктивные команды — кнопка человека. sandbox-exec проверяется на буте.",
      q6: "К чему можно подключить?",
      a6: "В этом релизе только Telegram. Локальная Ollama на localhost. Лишние сети (Discord, Slack, iMessage, …) явно вне целей v1.",
      closeTitle: "Запустите на своём Mac.",
      closeLede: "Clone, ./install.sh, модель, Telegram. Поставьте звезду, если нативная ставка для macOS вам близка.",
      docs: "Читать спецификацию",
      footName: "S.L.A.M 0.1.0-alpha",
      footTag: "Демон ваш. Данные ваши. Токен остаётся в Keychain.",
      footMeta: "MIT · 2026 · macOS на Apple Silicon",
    },
    sr: {
      skip: "Preskoči na sadržaj",
      navHow: "Kako radi",
      navSecurity: "Bezbednost",
      navFaq: "FAQ",
      navDocs: "Dokumentacija",
      navGitHub: "GitHub",
      badge: "Otvoreni kod · 0.1.0-alpha",
      heroTitle: "macOS agent\nkoji stvarno pripada vama.",
      heroAccent: "koji stvarno pripada vama.",
      lede: "Swift 6 LaunchAgent na Apple Silicon. Razgovor ide preko Telegrama; inferencija ostaje na lokalnom Ollama. Token bota je u Keychain-u. Komande modela idu pod Seatbelt. Nema cloud-sedišta, nema pretplate.",
      star: "Zvezda na GitHub-u",
      termCaption: "LaunchAgent transkript",
      termBody: `$ ./install.sh
release → ~/.local/bin/slam
LaunchAgent gui/$(id -u)/com.local.slam
$ launchctl print gui/$(id -u)/com.local.slam
state = running
$  /status
rss ~18 MB · cpu ≲ 1% · sandbox ok`,
      quoteGray: "Većina AI-asistenata je sedište koje iznajmljujete na tuđoj mašini.",
      quoteInk: "S.L.A.M je LaunchAgent koji je vaš na vašoj.",
      m1n: "1",
      m1k: "Nativni binarni fajl",
      m1d: "Swift 6 SPM izvršni paket. Ne treba Node, JVM ni Python okruženje.",
      m2n: "~18 MB",
      m2k: "Izmereni idle RSS",
      m2d: "Budžet specifikacije: RAM ≤ 100 MB i CPU ≲ 1% dok čeka long-poll.",
      m3n: "121",
      m3k: "Testova",
      m3d: "22 kompleta na javnom snimku. swift test je uslov za merge.",
      m4n: "1",
      m4k: "Kanal (alfa)",
      m4d: "Samo Telegram, namerno. Lokalni Ollama je putanja modela u ovom izdanju.",
      footMetrics: "VRAM se oslobađa posle svakog odgovora (Ollama keep_alive: 0). Mirovanje koristi QoS .utility / .background — E-jezgra.",
      howTitle: "Pokretanje posle clone",
      howLede: "Nema instalera curl sa tuđeg domena. Klonirajte javni repo, pokrenite ./install.sh, povucite lokalni model, pa pišite u Telegramu.",
      s1t: "Kloniraj repo",
      s1d: "Izvor istine je GitHub. Gradite na svom Mac-u Swift alatima kojima već verujete.",
      s1c: "git clone https://github.com/ValDagon/slam.git",
      s2t: "Instaliraj servis",
      s2d: "Release binarni fajl u ~/.local/bin, LaunchAgent plist, bootstrap gui/$(id -u). Traži BotFather token ako je Keychain prazan.",
      s2c: "./install.sh",
      s3t: "Povuci lokalni model",
      s3d: "U dokumentaciji je podrazumevano qwen2.5:7b. Inferencija je na vašoj mašini; demon ne isporučuje težine.",
      s3c: "ollama pull qwen2.5:7b",
      s4t: "Piši u Telegramu",
      s4d: "Nema GUI. /status javlja RSS, CPU, bazu i peščanik. Ćaskanje je potez modela; destruktivni shell čeka dugme.",
      s4c: "/status",
      secTitle: "Pristup shell-u koji možete da ograničite",
      secLede: "Analog „priznanice“ ovde je Seatbelt profil pod kojim dete stvarno radi — deny-default, uski upis, bez mreže, tajne nisu u fajlovima.",
      recK: "Seatbelt profil",
      recV: "SBPL · sandbox-exec",
      r1a: "deny",
      r1b: "default",
      r2a: "write",
      r2b: "samo WORKING_DIR/tmp  (alfa)",
      r3a: "network",
      r3b: "deny  (dete u peščaniku)",
      r4a: "sensitive",
      r4b: "~/.ssh · ~/.aws · Keychains · ~/Documents",
      r5a: "token",
      r5b: "Keychain — nikad .env ni config.json",
      r6a: "hitl",
      r6b: "destruktivni obrasci čekaju vaše dugme",
      recCap: "Model nikad ne vidi Keychain stavku. Alfa obim upisa je bezbednosni default, ne granica proizvoda 1.0.",
      f1t: "Nadgledane komande",
      f1d: "Destruktivni obrasci iz konfiguracije čekaju inline dugme u Telegramu (timeout 10 minuta, zatim odbijanje).",
      f2t: "OS peščanik",
      f2d: "sandbox-exec Seatbelt, ne Docker Desktop. Dimni test pri startu (FR-24): ako profil padne, kanal komandi je ugašen, demon živi.",
      f3t: "Politika workspace-a",
      f3d: "Čitanje: sistemske putanje za exec plus workspace. Upis: WORKING_DIR/tmp. Osetljiva stabla su izričito zabranjena.",
      f4t: "Keychain, ne fajlovi",
      f4d: "Token bota je kSecClassGenericPassword (service com.local.slam). Ne sme da se nađe u git-u, plist-u, logovima ili issues.",
      prodTitle: "Građen oko macOS-a",
      prodLede: "Jake strane su ograničenja, ne prezentacija: Swift 6, launchd, Keychain, Seatbelt, QoS, budžet mirovanja, keep_alive: 0.",
      p1t: "U potpunosti Swift 6",
      p1d: "SPM izvršni paket, jezički režim Swift 6, -strict-concurrency=complete. Deljivo mutabilno stanje živi u actor-ima ili je Sendable.",
      p2t: "LaunchAgent životni ciklus",
      p2d: "KeepAlive, RunAtLoad, ProcessType=Background. launchd poseduje proces; ne ostavljate večni run u Terminalu.",
      p3t: "Tajne u Keychain-u",
      p3d: "Telegram token nije u .env. config.json drži samo nestajne postavke (allowlist, model, putanje).",
      p4t: "Seatbelt izolacija",
      p4d: "Shell modela je Foundation.Process + sandbox-exec. Nativni Ollama alati write_file / run_shell, uz fence rezervu.",
      p5t: "Mirovanje na E-jezgrima",
      p5d: "QoS .utility / .background za čekanje. Spec: RAM ≤ 100 MB u mirovanju, CPU ≲ 1% između long-poll-ova.",
      p6t: "Higijena VRAM-a",
      p6d: "Ollama keep_alive: 0 na svakom zahtevu, plus idle unloader, tako da se GPU memorija laptopa oslobodi posle odgovora.",
      useTitle: "Šta možete danas",
      useLede: "Alfa: lični Telegram demon na jednom Mac-u. Nije višekanalna platforma. Pošten obim je bolji od lažnog kataloga.",
      u1t: "Lični asistent",
      u1d: "Ćaskanje iz Telegrama. Memorija je SQLite (GRDB, WAL, FTS5) na disku, ne iznajmljena cloud sveska.",
      u2t: "Shell u peščaniku",
      u2d: "Pitajte za prostor na disku ili listing workspace-a. Dete nema mrežu; upisi van tmp su zabranjeni.",
      u3t: "Fajlovi u tmp",
      u3d: "write_file i redirekcije u ovom izdanju smeju samo u WORKING_DIR/tmp. Ta granica će se proširiti.",
      u4t: "HITL potvrde",
      u4d: "Obrasci klase rm ne rade dok ne dodirnete inline dugme. stdout/stderr se vraćaju u ćaskanje.",
      u5t: "Zdravlje u ćaskanju",
      u5d: "/status javlja uptime, RSS, CPU, bazu i peščanik. Logovi su u ~/.local/state/slam/logs/.",
      u6t: "Lokalni model",
      u6d: "Podrazumevani model u dokumentaciji je qwen2.5:7b preko localhost Ollama. Druga lokalna imena rade kroz /model.",
      vsTitle: "Pošteno naspram ZeroClaw",
      vsLede: "ZeroClaw je jak Rust agent sa mnogo kanala. Ovaj projekat to ne zamenjuje. Poenta je nativni Swift / macOS-first.",
      vsCol: "S.L.A.M",
      vsZ: "ZeroClaw (javna dokumentacija, avg 2026)",
      vsR1a: "Stek",
      vsR1b: "Swift 6 + Apple framework-i + GRDB",
      vsR1c: "Rust, jedan binarni fajl",
      vsR2a: "macOS životni ciklus",
      vsR2b: "User LaunchAgent (KeepAlive, RunAtLoad)",
      vsR2c: "Cross-platform demon (nije launchd-first)",
      vsR3a: "Izolacija alata",
      vsR3b: "sandbox-exec SBPL, bez mreže u detetu",
      vsR3c: "Pairing, allowlist; opciono Docker",
      vsR4a: "Tajne",
      vsR4b: "Telegram token samo u Keychain-u",
      vsR4c: "U ovoj klasi često tajne u config-fajlu",
      vsR5a: "Kanali u v1",
      vsR5b: "Samo Telegram",
      vsR5c: "15–30+ mreža",
      vsNote: "Upis u workspace je samo alfa: danas pišemo samo u WORKING_DIR/tmp. Kasnije ćemo proširiti i/ili učiniti podesivim.",
      mapTitle: "Mapa puta, bez lažnih datuma",
      mapLede: "Stvari stižu kad su spremne. Ne kopiramo brojeve verzija konkurenata.",
      rA: "Isporučeno",
      rAt: "Alfa demon",
      rAd: "LaunchAgent, Telegram long-poll, lokalni Ollama, SQLite, Seatbelt, Keychain, HITL, 121 test.",
      rB: "Sledeće",
      rBt: "Širi workspace",
      rBd: "Skinuti default „piši samo u tmp“. deny-default i zabrane osetljivih putanja ostaju dok taj rad ne sleti.",
      rC: "Kasnije",
      rCt: "Ka 1.0",
      rCd: "Stabilan ugovor konfiguracije i bezbednosti, podesivi peščanik. Dodatne chat mreže ostaju non-goal dok ne odlučimo drugačije.",
      faqTitle: "Pitanja, odgovori",
      q1: "Šta je S.L.A.M?",
      a1: "S.L.A.M (Swift Light Agent for Mac) je nativni headless AI-agent za macOS (Apple Silicon): Swift 6 demon sa kojim razgovarate preko Telegrama, sa lokalnim Ollama za inferenciju i sandbox-exec za komande modela. Nema GUI — launchd poseduje proces.",
      q2: "Da li je besplatan?",
      a2: "Da. MIT licenca. Nema pretplate i nema hostovanog sedišta. Plaćate samo hardver i lokalni model koji pokrećete.",
      q3: "Koliko je lagan?",
      a3: "Spec budžet u mirovanju je RAM ≤ 100 MB i CPU ≲ 1%. Izmereni idle RSS na razvojnom Mac-u bio je oko 18 MB. Javni snimak zatvaraju 121 test / 22 kompleta.",
      q4: "Da li podaci napuštaju mašinu?",
      a4: "Demon i Ollama rade lokalno. Telegram je kanal upravljanja, pa poruke koje pošaljete idu na Telegram API — to je svojstvo bota. Nema S.L.A.M oblaka u sredini. Token bota nikad ne sedi u fajlu.",
      q5: "Kako je osiguran?",
      a5: "Token u Keychain-u. Allowlist Telegram korisničkih ID-jeva. Seatbelt deny-default sa upisom samo u tmp u alfi. Destruktivne komande traže ljudsko dugme. sandbox-exec se proverava pri startu.",
      q6: "Na šta može da se poveže?",
      a6: "U ovom izdanju samo Telegram. Lokalni Ollama na localhost. Dodatne mreže (Discord, Slack, iMessage, …) su izričiti non-goal za v1.",
      closeTitle: "Pokrenite ga na svom Mac-u.",
      closeLede: "Clone, ./install.sh, model, Telegram. Stavite zvezdu ako vam je nativna macOS opklada korisna.",
      docs: "Pročitaj specifikaciju",
      footName: "S.L.A.M 0.1.0-alpha",
      footTag: "Demon je vaš. Podaci su vaši. Token ostaje u Keychain-u.",
      footMeta: "MIT · 2026 · Apple Silicon macOS",
    },
  };

  const htmlKeys = new Set(["heroTitle"]);

  let lang = "en";

  function detectLang() {
    const saved = localStorage.getItem("sa-lang");
    if (saved && strings[saved]) return saved;
    const nav = (navigator.languages || [navigator.language || "en"]).map((x) =>
      String(x).toLowerCase()
    );
    if (nav.some((x) => x.startsWith("ru"))) return "ru";
    if (nav.some((x) => x.startsWith("sr"))) return "sr";
    return "en";
  }

  function applyLang(next) {
    lang = next;
    localStorage.setItem("sa-lang", lang);
    document.documentElement.lang = lang;
    const pack = strings[lang];
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      const value = pack[key];
      if (value == null) return;
      if (htmlKeys.has(key)) {
        const parts = value.split("\n");
        if (parts.length === 2) {
          el.innerHTML = `${escapeHtml(parts[0])}<br><span class="accent">${escapeHtml(parts[1])}</span>`;
        } else {
          el.textContent = value;
        }
      } else if (el.tagName === "PRE" || el.hasAttribute("data-pre")) {
        el.textContent = value;
      } else {
        el.textContent = value;
      }
    });
    const spec = {
      en: "https://github.com/ValDagon/slam/blob/main/docs/SPEC.md",
      ru: "https://github.com/ValDagon/slam/blob/main/docs/SPEC.ru.md",
      sr: "https://github.com/ValDagon/slam/blob/main/docs/SPEC.sr.md",
    };
    document.querySelectorAll("[data-spec]").forEach((a) => {
      a.setAttribute("href", spec[lang]);
    });
    document.querySelectorAll(".copy-btn").forEach((btn) => {
      if (!btn.classList.contains("is-copied")) btn.textContent = COPY_LABEL[lang];
    });
    document.querySelectorAll("[data-i18n-aria]").forEach((el) => {
      const key = el.getAttribute("data-i18n-aria");
      if (pack[key]) el.setAttribute("aria-label", pack[key]);
    });
    document.querySelectorAll(".lang button").forEach((btn) => {
      btn.setAttribute("aria-pressed", btn.dataset.lang === lang ? "true" : "false");
    });
    const toggle = document.querySelector(".nav-toggle");
    if (toggle) {
      const open = toggle.getAttribute("aria-expanded") === "true";
      toggle.textContent = open ? MENU_CLOSE[lang] : MENU_OPEN[lang];
    }
    document.title = "S.L.A.M — Swift Light Agent for Mac";
  }

  function escapeHtml(s) {
    return s
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  }

  async function copyInstall() {
    const live = document.getElementById("copy-live");
    try {
      await navigator.clipboard.writeText(INSTALL);
    } catch {
      const ta = document.createElement("textarea");
      ta.value = INSTALL;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    document.querySelectorAll(".copy-btn").forEach((b) => {
      b.classList.add("is-copied");
      b.textContent = COPIED_LABEL[lang];
      window.setTimeout(() => {
        b.classList.remove("is-copied");
        b.textContent = COPY_LABEL[lang];
      }, 1600);
    });
    if (live) live.textContent = COPIED_LABEL[lang];
  }

  function setupFaq() {
    document.querySelectorAll(".faq-item").forEach((item, i) => {
      const btn = item.querySelector("button");
      const panel = item.querySelector(".answer");
      if (!btn || !panel) return;
      const id = `faq-panel-${i}`;
      panel.id = id;
      btn.setAttribute("aria-controls", id);
      btn.setAttribute("aria-expanded", "false");
      btn.addEventListener("click", () => {
        const open = item.getAttribute("data-open") === "true";
        document.querySelectorAll(".faq-item").forEach((other) => {
          other.setAttribute("data-open", "false");
          const b = other.querySelector("button");
          if (b) b.setAttribute("aria-expanded", "false");
        });
        if (!open) {
          item.setAttribute("data-open", "true");
          btn.setAttribute("aria-expanded", "true");
        }
      });
    });
  }

  function setupNav() {
    const toggle = document.querySelector(".nav-toggle");
    const panel = document.getElementById("nav-panel");
    if (!toggle || !panel) return;
    toggle.addEventListener("click", () => {
      const open = toggle.getAttribute("aria-expanded") === "true";
      toggle.setAttribute("aria-expanded", open ? "false" : "true");
      panel.classList.toggle("is-open", !open);
      toggle.textContent = !open ? MENU_CLOSE[lang] : MENU_OPEN[lang];
    });
    panel.querySelectorAll("a").forEach((a) => {
      a.addEventListener("click", () => {
        toggle.setAttribute("aria-expanded", "false");
        panel.classList.remove("is-open");
        toggle.textContent = MENU_OPEN[lang];
      });
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    applyLang(detectLang());
    document.querySelectorAll(".lang button").forEach((btn) => {
      btn.addEventListener("click", () => applyLang(btn.dataset.lang));
    });
    document.querySelectorAll(".copy-btn").forEach((btn) => {
      btn.addEventListener("click", copyInstall);
    });
    setupFaq();
    setupNav();
  });
})();
