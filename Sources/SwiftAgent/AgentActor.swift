import Foundation

/// Daemon state machine: owns config mutation, counters and routing decisions.
/// Conversation history lives in SQLite (stage 3); the actor only orchestrates.
actor AgentActor {
    struct Counters: Sendable, Equatable {
        var updatesReceived = 0
        var reconnections = 0
        var conflicts409 = 0
        var modelReplies = 0
        var commandsExecuted = 0
        var confirmationsRequested = 0
        var confirmationsDenied = 0
    }

    private(set) var config: AgentConfig
    private let configURL: URL
    private let state: StateStore
    private let db: DatabaseManager?
    private let startedAt = Date()
    private(set) var counters = Counters()

    init(config: AgentConfig, configURL: URL, state: StateStore, database: DatabaseManager? = nil) {
        self.config = config
        self.configURL = configURL
        self.state = state
        self.db = database
        if let database {
            Task(priority: .utility) { await self.importFileStateIfNeeded(into: database) }
        }
    }

    var uptimeSeconds: TimeInterval { Date().timeIntervalSince(startedAt) }

    // MARK: - Ingress

    /// Applies the allowlist gate (FR-7). Strangers get a pairing offer on /start only.
    func route(_ update: TgUpdate) -> IngressDecision {
        counters.updatesReceived += 1
        guard let chatId = update.chatId,
              let senderId = update.senderId,
              let text = update.effectiveText, !text.isEmpty else { return .ignore }
        if config.telegramAllowlist.contains(senderId) {
            return .deliver(RoutedUpdate(
                chatId: chatId,
                senderId: senderId,
                text: text,
                isCommand: text.hasPrefix("/")
            ))
        }
        if case .start = CommandParser.Parsed.from(text) {
            return .pairing(chatId: chatId, senderId: senderId)
        }
        return .ignore
    }

    static func pairingText(senderId: Int64) -> String {
        """
        Доступ закрыт. Ваш Telegram ID: \(senderId)
        Владелец может выдать доступ командой /allow \(senderId) или правкой config.json.
        """
    }

    enum ReplyPlan: Sendable {
        /// Command or service answer: send as one message.
        case plain(String)
        /// Conversation turn: stream the model answer through the publisher.
        case modelStream(userText: String, context: [ChatMessage])
    }

    /// What the listener must do after a model reply has been published.
    enum PostStreamAction: Sendable {
        case none
        /// A ```run block was found in the model answer.
        case execute(commandPlan: CommandSafety.Plan)
    }

    /// Classification result for a native tool call (FR-21), mirroring
    /// `PostStreamAction`'s split between "run now" and "needs the HITL gate" —
    /// `run_shell` reuses `CommandSafety.plan` and the exact same confirmation
    /// machinery as the fence fallback, no parallel mechanism.
    enum ToolCallPlan: Sendable {
        case writeFile(path: String, content: String)
        case runShell(CommandSafety.Plan)
        case invalid(String)
    }

    /// Decides what to do with a routed update without producing the answer:
    /// commands resolve synchronously, conversation turns become model plans.
    func planReply(for routed: RoutedUpdate) async -> ReplyPlan {
        switch CommandParser.Parsed.from(routed.text) {
        case .start:
            return .plain("\(AppIdentity.displayName) on duty. /help — список команд.")
        case .help:
            return .plain(Self.helpText)
        case .status:
            return .plain(await statusText())
        case .allow(let id):
            return .plain(await allow(id, sender: routed.senderId))
        case .deny(let id):
            return .plain(deny(id, sender: routed.senderId))
        case .model(let name):
            return .plain(await setModel(name, sender: routed.senderId))
        case .unknownCommand(let raw):
            return .plain("Неизвестная команда: \(raw). /help — список команд.")
        case .plain(let text):
            counters.modelReplies += 1
            do {
                try await db?.appendMessage(sessionId: routed.chatId, role: "user", content: text)
                let context = try await buildContext(chatId: routed.chatId)
                return .modelStream(userText: text, context: context)
            } catch {
                sharedLogger.error("agent", "history write/read failed: \(error)")
                // Degraded mode: answer from this single turn only.
                var fallback: [ChatMessage] = []
                if let systemPrompt = config.systemPrompt, !systemPrompt.isEmpty {
                    fallback.append(.system(systemPrompt))
                }
                fallback.append(.user(text))
                return .modelStream(userText: text, context: fallback)
            }
        }
    }

    private func buildContext(chatId: Int64) async throws -> [ChatMessage] {
        guard let db else { return [] }
        return try await db.buildContext(
            chatId: chatId,
            maxMessages: config.maxContextMessages,
            budgetChars: config.resolvedContextBudgetChars,
            systemPrompt: config.systemPrompt
        )
    }

    /// Records the assistant's answer once streaming completes.
    /// Awaited by the listener after publishing, so persistence order matches chat order.
    func noteAssistantReply(chatId: Int64, text: String) async {
        guard let db else { return }
        do {
            try await db.appendMessage(sessionId: chatId, role: "assistant", content: text)
        } catch {
            sharedLogger.error("agent", "assistant reply not persisted: \(error)")
        }
    }

    // MARK: - Command execution planning (stage 4)

    /// Inspects a finished model reply for a ```run block and classifies it.
    func postStreamAction(for modelReply: String) -> PostStreamAction {
        guard let command = CommandSafety.extractRunCommand(from: modelReply) else {
            return .none
        }
        let plan = CommandSafety.plan(
            command: command,
            extraPatterns: config.destructivePatterns ?? []
        )
        if plan.requiresConfirmation {
            counters.confirmationsRequested += 1
        } else {
            counters.commandsExecuted += 1
        }
        return .execute(commandPlan: plan)
    }

    // MARK: - Native tool calls (FR-21)

    /// The catalog offered to Ollama for this turn; empty disables native
    /// tools entirely (config opt-out) and leaves only the fence fallback.
    func toolDefinitions() -> [OllamaToolDefinition] {
        config.resolvedUseNativeTools ? ToolCatalog.all : []
    }

    /// Classifies one model-requested tool call. `run_shell` funnels through
    /// the identical destructive-pattern check used by the fence path so a
    /// dangerous command always needs the same button confirmation either way.
    func planToolCall(_ call: OllamaToolCall) -> ToolCallPlan {
        switch call.function.name {
        case "write_file":
            guard let path = call.function.arguments["path"]?.stringValue,
                  let content = call.function.arguments["content"]?.stringValue else {
                return .invalid("write_file: нужны строковые аргументы path и content")
            }
            return .writeFile(path: path, content: content)
        case "run_shell":
            guard let command = call.function.arguments["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid("run_shell: нужен непустой строковый аргумент command")
            }
            let plan = CommandSafety.plan(command: command, extraPatterns: config.destructivePatterns ?? [])
            if plan.requiresConfirmation {
                counters.confirmationsRequested += 1
            } else {
                counters.commandsExecuted += 1
            }
            return .runShell(plan)
        default:
            return .invalid("неизвестный инструмент: \(call.function.name)")
        }
    }

    /// Executes `write_file`: validates the path is inside WORKING_DIR/tmp
    /// (`FileWriteTool.resolveSafePath`), then writes through the same
    /// sandbox-exec + ProcessRunner path as any other command — the SBPL
    /// `file-write*` rule is the second, OS-level barrier (FR-22 parity).
    func executeWriteFile(path: String, content: String, runner: ProcessRunner, profileURL: URL?) async -> String {
        guard content.utf8.count <= FileWriteTool.maxContentBytes else {
            return "отклонено: содержимое больше \(FileWriteTool.maxContentBytes) байт"
        }
        let ws = config.resolvedWorkingDirPath
        let paths = SandboxProfile.Paths(workingDir: ws)
        switch FileWriteTool.resolveSafePath(path, tmpDir: paths.workingTmp) {
        case .failure(let error):
            return "отклонено: \(error)"
        case .success(let absolutePath):
            let command = FileWriteTool.writeCommand(content: content, absolutePath: absolutePath)
            let invocation: SandboxInvocation
            switch (config.resolvedSandboxEnabled, profileURL) {
            case (true, .some(let url)):
                invocation = .sandbox(profileFileURL: url, paths: paths)
            default:
                invocation = .none
            }
            let result = await runner.run(
                executable: SandboxProfile.zshPath,
                arguments: ["-c", command],
                environment: [:],
                workingDirectory: ws,
                sandbox: invocation
            )
            counters.commandsExecuted += 1
            if result.succeeded {
                return "файл записан: \(path) (\(content.utf8.count) байт)"
            }
            return "ошибка записи (\(path)): \(Self.shortFailureReason(result))"
        }
    }

    private static func shortFailureReason(_ result: ProcessResult) -> String {
        switch result.outcome {
        case .failedToLaunch(let error):
            return "запуск не удался: \(error)"
        case .timedOut:
            return "превышен таймаут"
        case .completed:
            if case .deniedSandbox = result.sandboxVerdict {
                return "остановлено песочницей"
            }
            if !result.stderr.isEmpty {
                return Self.truncateForChat(result.stderr, limit: 500)
            }
            return "exit \(result.exitCode ?? -1)"
        }
    }

    /// Persists an HITL request and returns its database row id (nil without db).
    func storePendingConfirmation(chatId: Int64, command: String) async -> Int64? {
        guard let db else { return nil }
        do {
            return try await db.insertPendingConfirmation(
                chatId: chatId,
                messageId: nil,
                command: command,
                ttl: config.resolvedConfirmationTimeout
            )
        } catch {
            sharedLogger.error("agent", "confirmation not persisted: \(error)")
            return nil
        }
    }

    /// Validates a callback button press against the stored HITL request:
    /// same chat, not expired. The row is consumed before returning.
    func resolveConfirmation(id: Int64, chatId: Int64, senderId: Int64, approve: Bool) async -> ConfirmationResolution {
        guard let db else { return .ignored }
        let pending = (try? await db.pendingConfirmation(id: id, chatId: chatId)) ?? nil
        guard let pending else {
            return .ignored
        }
        // Consume first so a retry can never double-execute.
        _ = try? await db.deletePendingConfirmation(id: id)
        // Button presses come from the chat the request was posted to; the
        // sender is already allowlist-gated upstream (route()).
        if let ownerId = config.ownerId, ownerId != senderId,
           !config.telegramAllowlist.contains(senderId) {
            return .ignored
        }
        if approve {
            counters.commandsExecuted += 1
            return .approved(command: pending.command)
        }
        counters.confirmationsDenied += 1
        return .cancelled
    }

    /// Runs one approved command inside the sandbox and returns the report text.
    func executeApprovedCommand(_ command: String, runner: ProcessRunner, profileURL: URL?) async -> String {
        let ws = config.resolvedWorkingDirPath
        let paths = SandboxProfile.Paths(workingDir: ws)
        let invocation: SandboxInvocation
        switch (config.resolvedSandboxEnabled, profileURL) {
        case (true, .some(let url)):
            invocation = .sandbox(profileFileURL: url, paths: paths)
        default:
            invocation = .none
        }
        let result = await runner.run(
            executable: SandboxProfile.zshPath,
            arguments: ["-c", command],
            environment: [:],
            workingDirectory: ws,
            sandbox: invocation
        )
        let sandboxed: Bool
        if case .sandbox = invocation { sandboxed = true } else { sandboxed = false }
        return Self.render(
            result: result,
            command: command,
            workingDir: ws,
            sandboxEnabled: sandboxed
        )
    }

    static func render(
        result: ProcessResult,
        command: String,
        workingDir: String = "",
        sandboxEnabled: Bool = false
    ) -> String {
        var lines = ["$ \(command)"]
        if sandboxEnabled, let scope = CommandSafety.sandboxScopeWarning(command: command, workingDir: workingDir) {
            lines.append(scope)
        }
        switch result.outcome {
        case .failedToLaunch(let error):
            lines.append("запуск не удался: \(error)")
        case .timedOut:
            lines.append("превышен таймаут команды")
            if !result.stdout.isEmpty { lines.append("stdout:\n\(Self.truncateForChat(result.stdout))") }
        case .completed:
            if let signal = result.exitSignal {
                if case .deniedSandbox = result.sandboxVerdict {
                    lines.append("остановлено песочницей (сигнал \(signal))")
                } else {
                    lines.append("завершено сигналом \(signal)")
                }
            } else {
                lines.append("exit: \(result.exitCode ?? -1)")
            }
            if !result.stdout.isEmpty { lines.append("stdout:\n\(Self.truncateForChat(result.stdout))") }
            if !result.stderr.isEmpty { lines.append("stderr:\n\(Self.truncateForChat(result.stderr))") }
            if sandboxEnabled,
               result.stderr.localizedCaseInsensitiveContains("Operation not permitted"),
               CommandSafety.sandboxScopeWarning(command: command, workingDir: workingDir) == nil {
                if CommandSafety.looksLikeWriteAttempt(command) {
                    lines.append(
                        "подсказка: Operation not permitted — sandbox разрешает запись только в \(workingDir)/tmp; сам workspace и остальное дерево — read-only (FR-22). Пишите файл через `tmp/<имя>`."
                    )
                } else {
                    lines.append(
                        "подсказка: Operation not permitted — sandbox разрешает чтение только в workspace (\(workingDir)); ~ закрыт (FR-22)."
                    )
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - One-time file → kv migration

    /// Imports the legacy state.json values (tg_offset etc.) into kv on first
    /// boot with the database present; kv becomes canonical afterwards.
    private func importFileStateIfNeeded(into database: DatabaseManager) async {
        let keys = [TelegramListener.offsetKey]
        for key in keys {
            guard let value = state.get(key), !value.isEmpty else { continue }
            do {
                if let existing = try await database.getValue(forKey: key), !existing.isEmpty {
                    continue
                }
                try await database.setValue(value, forKey: key)
                sharedLogger.info("storage", "migrated '\(key)' from state.json into kv")
            } catch {
                sharedLogger.error("storage", "kv import of '\(key)' failed (kept in file): \(error)")
            }
        }
    }

    // MARK: - Allowlist management

    func allow(_ id: Int64, sender: Int64) async -> String {
        guard isOwner(sender) else {
            return "Только владелец (первый в allowlist) может выдавать доступ."
        }
        if config.telegramAllowlist.contains(id) {
            return "\(id) уже в allowlist."
        }
        config.telegramAllowlist.append(id)
        do {
            try ConfigStore.write(config, url: configURL)
            return "\(id) добавлен в allowlist."
        } catch {
            config.telegramAllowlist.removeAll { $0 == id }
            return "Не удалось записать конфиг: \(error)"
        }
    }

    func setModel(_ name: String, sender _: Int64) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Укажите имя модели: /model <name>"
        }
        let previous = config.model
        config.model = trimmed
        do {
            try ConfigStore.write(config, url: configURL)
            return "Модель переключена на \(trimmed)."
        } catch {
            config.model = previous
            return "Не удалось записать конфиг: \(error)"
        }
    }

    func deny(_ id: Int64, sender: Int64) -> String {
        guard isOwner(sender) else {
            return "Только владелец может отзывать доступ."
        }
        if id == config.ownerId {
            return "Нельзя удалить владельца из allowlist."
        }
        guard let index = config.telegramAllowlist.firstIndex(of: id) else {
            return "\(id) не найден в allowlist."
        }
        config.telegramAllowlist.remove(at: index)
        do {
            try ConfigStore.write(config, url: configURL)
            return "\(id) удалён из allowlist."
        } catch {
            config.telegramAllowlist.insert(id, at: index)
            return "Не удалось записать конфиг: \(error)"
        }
    }

    private func isOwner(_ sender: Int64) -> Bool {
        config.ownerId == sender
    }

    // MARK: - Status

    func statusText() async -> String {
        var lines = [
            AppIdentity.versionLine,
            "uptime: \(Int(uptimeSeconds))s",
            "state size: \(state.fileSizeBytes().map { "\($0) B" } ?? "?")",
            "updates received: \(counters.updatesReceived)",
            "reconnects: \(counters.reconnections)",
            "conflicts 409: \(counters.conflicts409)",
            "model replies: \(counters.modelReplies)",
            "commands executed: \(counters.commandsExecuted)",
            "confirmations: \(counters.confirmationsRequested) requested, \(counters.confirmationsDenied) denied",
            "model: \(config.model)",
            "allowlist: \(config.telegramAllowlist.count) user(s)",
        ]
        lines.append("mode: ollama stream (\(config.resolvedOllamaURL.host ?? "?"))")
        lines.append("native tools: \(config.resolvedUseNativeTools ? "on" : "off") (fence ```run всегда доступен как fallback)")
        lines.append("sandbox: \(config.resolvedSandboxEnabled ? "on" : "off") (workspace \(config.resolvedWorkingDirPath))")
        if let sample = ResourceMonitor.sample(uptime: uptimeSeconds) {
            lines.append("resources: rss \(String(format: "%.1f", sample.rssMB)) MB, avg cpu \(String(format: "%.2f", sample.avgCPUPercent))% (budget ≤100 MB / ≤1%)")
        }
        if let db {
            lines.append(contentsOf: await db.statusLines())
        }
        return lines.joined(separator: "\n")
    }

    /// Telegram message limit is 4096 chars; leave room for framing.
    static func truncateForChat(_ text: String, limit: Int = 3000) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n… (обрезано)"
    }

    static let helpText = """
    Команды:
    /start — приветствие
    /help — эта справка
    /status — состояние демона
    /model <name> — переключить модель Ollama
    /allow <id> — добавить пользователя (владелец)
    /deny <id> — убрать пользователя (владелец)

    Остальной текст уходит в модель и отвечает стримингом.
    Модель может исполнять команды через нативные tools Ollama
    (write_file, run_shell) или, если инструмент не вызван, через
    блок ```run в тексте ответа — оба пути идут через одну и ту же
    песочницу (workspace-каталог); деструктивные команды
    требуют подтверждения кнопкой в чате.
    """

    // MARK: - Accessors for listener

    func currentModel() -> String { config.model }

    // MARK: - Counters for listener

    func noteReconnect() { counters.reconnections += 1 }
    func noteConflict() { counters.conflicts409 += 1 }
}
