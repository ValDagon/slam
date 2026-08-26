import Foundation

@main
struct DaemonMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        switch args.first {
        case "set-token":
            await runSetToken()
        case "clear-token":
            await runClearToken()
        case "repair-keychain-acl":
            await runRepairKeychainACL()
        case "probe-keychain":
            await runProbeKeychain()
        case "run", .none:
            await runDaemon()
        case "version", "--version", "-v":
            print("\(AppIdentity.displayName) \(AppVersion.string)")
        case "help", "--help", "-h":
            print(Self.usage)
        case let other:
            FileHandle.standardError.write(Data("unknown command: \(other ?? "")\n\n\(Self.usage)\n".utf8))
            exit(2)
        }
    }

    // MARK: - set-token

    static func runSetToken() async {
        print("Вставьте токен Telegram-бота (ввод скрытой строкой не поддерживается, значение уйдёт только в Keychain):")
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            FileHandle.standardError.write(Data("пустой ввод, отмена\n".utf8))
            exit(1)
        }
        do {
            try KeychainStore().save(secret: line.trimmingCharacters(in: .whitespaces), account: "telegram-bot-token")
            print("Токен сохранён в Keychain (service=\(AppIdentity.keychainService), account=telegram-bot-token).")
            print("ACL доверяет \(Paths.installedBinaryURL().path) и текущему бинарнику. Если macOS спросит доступ — «Always Allow» один раз.")
        } catch {
            FileHandle.standardError.write(Data("ошибка Keychain: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Deletes the bot token from both Keychain variants. Does not print the secret.
    static func runClearToken() async {
        do {
            try KeychainStore().delete(account: "telegram-bot-token")
            print("Токен удалён из Keychain (service=\(AppIdentity.keychainService), account=telegram-bot-token).")
        } catch {
            FileHandle.standardError.write(Data("ошибка Keychain: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Exit 0 if the LaunchAgent binary can read the token without UI (ACL OK).
    /// Used by install.sh to skip rewrite+password dialogs when ACL already matches.
    static func runProbeKeychain() async {
        do {
            guard let token = try KeychainStore().load(account: "telegram-bot-token", allowInteraction: false),
                  !token.isEmpty else {
                exit(1)
            }
            exit(0)
        } catch {
            exit(1)
        }
    }

    // MARK: - repair-keychain-acl

    /// After install.sh replaces an ad-hoc binary, refresh login-keychain ACL without
    /// re-typing the token. May show one Keychain dialog — choose Always Allow.
    static func runRepairKeychainACL() async {
        do {
            try KeychainStore().repairTrustedAccess(account: "telegram-bot-token")
            print("Keychain ACL обновлён для \(Paths.installedBinaryURL().path).")
        } catch let error as KeychainError where error == .itemNotFound {
            FileHandle.standardError.write(Data("токен не найден — сначала set-token\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("ошибка Keychain ACL: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - daemon

    static func runDaemon() async {
        sharedLogger = FileLogger()
        let logger = sharedLogger
        logger.info("boot", "\(AppIdentity.versionLine) starting")

        let lock = SingleInstanceLock()
        guard lock.acquire() else {
            logger.logSync(.error, "boot", "another \(AppIdentity.cliName) instance is running (agent.lock held); exiting")
            exit(1)
        }

        let configURL = AgentConfig.configFileURL()
        let config: AgentConfig
        do {
            let (loaded, created) = try ConfigStore.loadOrCreate(url: configURL)
            config = loaded
            if created {
                logger.info("config", "created default config at \(configURL.path); добавьте свой Telegram ID в telegram_allowlist")
            }
        } catch {
            logger.error("config", "cannot load config: \(error)")
            exit(1)
        }

        if config.telegramAllowlist.isEmpty {
            logger.error("allowlist", "telegram_allowlist пуст — бот будет игнорировать всех. Вписать ID в \(configURL.path) или отправить /allow <id> после ручного добавления владельца.")
        }

        let keychain = KeychainStore()
        // No password sheets under launchd: ACL must already trust this binary.
        guard let token = try? keychain.load(account: "telegram-bot-token", allowInteraction: false), !token.isEmpty else {
            logger.error("keychain", "токен недоступен без UI (нет записи или ACL). Выполните: \(AppIdentity.cliName) set-token  или  ./install.sh (repair)")
            exit(1)
        }

        let state = FileStateStore()

        let ollama = OllamaClient(baseURL: config.resolvedOllamaURL)

        // Storage (stage 3). The daemon must boot even without a database:
        // on failure we degrade to the pre-stage-3 behavior and keep polling.
        let database: DatabaseManager?
        do {
            let db = try DatabaseManager(
                quotaOverrideBytes: config.storageQuotaBytes.map(Int64.init),
                provider: ollama,
                modelName: config.model,
                logger: logger
            )
            database = db
            let maintenance = MaintenanceLoop(database: db, logger: logger)
            maintenance.start()
            logger.info("storage", "sqlite ready at \(Paths.databaseURL().path)")
        } catch {
            database = nil
            logger.error("storage", "database unavailable, running without persistence: \(error)")
        }

        let agent = AgentActor(config: config, configURL: configURL, state: state, database: database)
        let client = TelegramClient(token: token)

        let publisher = StreamingTelegramPublisher(client: client, logger: logger)
        let unloader = IdleUnloader(
            provider: ollama,
            modelName: config.model,
            idleMinutes: config.idleUnloadMinutes,
            logger: logger
        )

        // Stage 4: sandbox profile + command runner. The boot smoke test (FR-24)
        // decides whether the ```run channel goes live; failure is non-fatal.
        var commandRunner: ProcessRunner?
        var sandboxProfileURL: URL?
        if !config.resolvedSandboxEnabled {
            logger.info("sandbox", "disabled by config; command execution runs unsandboxed")
            commandRunner = ProcessRunner(config: .init(timeout: config.resolvedCommandTimeout))
        } else {
            let ws = config.resolvedWorkingDirPath
            let paths = SandboxProfile.Paths(workingDir: ws)
            do {
                try FileManager.default.createDirectory(atPath: paths.workingTmp, withIntermediateDirectories: true)
                let url = Paths.stateDirectoryURL().appendingPathComponent("sandbox.sb")
                try SandboxProfile.write(to: url, paths: paths)
                sandboxProfileURL = url
            } catch {
                logger.error("sandbox", "profile setup failed: \(error); ```run execution disabled")
            }
            if sandboxProfileURL != nil {
                switch await SandboxProfile.smokeTest(paths: paths) {
                case .ok:
                    logger.info("sandbox", "smoke test passed (\(ws))")
                    commandRunner = ProcessRunner(config: .init(timeout: config.resolvedCommandTimeout))
                case .failure(let reason):
                    logger.error("sandbox", "SMOKE FAILED: \(reason); ```run execution disabled")
                    sandboxProfileURL = nil
                }
            }
        }

        if commandRunner != nil, config.resolvedUseNativeTools {
            logger.info("boot", "native tools on (write_file, run_shell); fence ```run is fallback")
        } else if commandRunner != nil {
            logger.info("boot", "native tools off; fence ```run only")
        }

        do {
            let me = try await client.getMe()
            logger.info("boot", "authenticated as @\(me.username ?? String(me.id))")
        } catch {
            logger.error("boot", "getMe failed: \(error)")
            exit(1)
        }

        let listener = TelegramListener(
            client: client,
            state: state,
            agent: agent,
            logger: logger,
            backoff: BackoffCalculator(base: 2, maxDelay: 300),
            provider: ollama,
            publisher: publisher,
            unloader: unloader,
            database: database,
            commandRunner: commandRunner,
            sandboxProfileURL: sandboxProfileURL
        )
        unloader.start()

        await withTaskGroup(of: Void.self) { group in
            installSignalHandlers { logger.info("signal", "shutdown requested") }
            group.addTask(priority: .utility) {
                await listener.run()
            }
            await group.next()
            group.cancelAll()
        }

        lock.release()
        logger.info("boot", "shutdown complete")
        exit(0)
    }

    /// SIGINT/SIGTERM cancel the listener task for a graceful stop.
    static func installSignalHandlers(_ onSignal: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .utility))
            source.setEventHandler { onSignal() }
            source.resume()
            signalSources.append(source)
        }
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    static var usage: String {
        """
        \(AppIdentity.displayName) — \(AppIdentity.expansion)
        нативный headless AI-демон macOS

        Использование:
          \(AppIdentity.cliName) set-token            сохранить токен бота в Keychain (stdin)
          \(AppIdentity.cliName) clear-token          удалить токен из Keychain (оба варианта, без печати)
          \(AppIdentity.cliName) repair-keychain-acl  обновить ACL Keychain под установленный бинарник
          \(AppIdentity.cliName) probe-keychain       проверить чтение токена без UI (exit 0/1)
          \(AppIdentity.cliName) run                  запустить демона
          \(AppIdentity.cliName) version              показать версию
        """
    }
}
