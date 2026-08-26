import Foundation

/// Long polling loop: getUpdates with timeout=30, persisted offset,
/// exponential backoff with full jitter, 409 conflict detection.
///
/// Idle CPU is ~0%: the task suspends on URLSession I/O or Task.sleep.
/// A crashed Ollama surfaces as a failed stream and never kills the loop:
/// the user gets an error message, polling continues.
struct TelegramListener: Sendable {
    let client: TelegramClient
    let state: StateStore
    let agent: AgentActor
    let logger: FileLogger
    let backoff: BackoffCalculator
    private let provider: any ModelProvider
    private let publisher: StreamingTelegramPublisher
    private let unloader: IdleUnloader?
    /// Canonical offset storage from stage 3; state.json stays a fallback.
    private let database: DatabaseManager?
    /// Command execution (stage 4); nil disables the ```run channel entirely.
    private let commandRunner: ProcessRunner?
    /// Materialized SBPL profile; nil means run without sandbox.
    private let sandboxProfileURL: URL?

    static let offsetKey = "tg_offset"
    /// Bounds the write_file/run_shell → model → write_file… round-trip so a
    /// confused model can never loop the daemon forever (no busy-wait: each
    /// hop is one awaited network round-trip, just capped in count).
    static let maxToolHops = 4

    init(
        client: TelegramClient,
        state: StateStore,
        agent: AgentActor,
        logger: FileLogger,
        backoff: BackoffCalculator,
        provider: any ModelProvider,
        publisher: StreamingTelegramPublisher,
        unloader: IdleUnloader? = nil,
        database: DatabaseManager? = nil,
        commandRunner: ProcessRunner? = nil,
        sandboxProfileURL: URL? = nil
    ) {
        self.client = client
        self.state = state
        self.agent = agent
        self.logger = logger
        self.backoff = backoff
        self.provider = provider
        self.publisher = publisher
        self.unloader = unloader
        self.database = database
        self.commandRunner = commandRunner
        self.sandboxProfileURL = sandboxProfileURL
    }

    func run() async {
        await prepareWebhookState()
        var backoff = self.backoff
        while !Task.isCancelled {
            do {
                let offset = await currentOffset()
                let updates = try await client.getUpdates(offset: offset, timeoutSeconds: 30)
                backoff.reset()
                if !updates.isEmpty {
                    logger.debug("listener", "received \(updates.count) update(s)")
                }
                for update in updates {
                    await Task(priority: .userInitiated) {
                        await handle(update)
                    }.value
                }
            } catch TelegramAPIError.conflict {
                await agent.noteConflict()
                logger.error("listener", "\(TelegramAPIError.conflict)")
            } catch TelegramAPIError.rateLimit(let retryAfter) {
                let wait = TimeInterval(retryAfter ?? 5)
                logger.info("listener", "rate limited, sleeping \(wait)s")
                await sleep(seconds: wait)
            } catch is CancellationError {
                return
            } catch {
                await agent.noteReconnect()
                let delay = backoff.next()
                logger.error("listener", "getUpdates failed: \(error); retrying in \(String(format: "%.1f", delay))s")
                await sleep(seconds: delay)
            }
        }
    }

    /// If a webhook is set, getUpdates would conflict with it: remove it first.
    private func prepareWebhookState() async {
        do {
            let info = try await client.getWebhookInfo()
            if !info.url.isEmpty {
                logger.info("listener", "webhook found (\(info.url)), deleting it to use long polling")
                _ = try? await client.deleteWebhook(dropPendingUpdates: false)
            }
        } catch {
            logger.info("listener", "getWebhookInfo failed (continuing): \(error)")
        }
    }

    private func handle(_ update: TgUpdate) async {
        await persistOffset(update.updateId)
        if let callback = update.callbackQuery {
            await handleCallback(callback)
            return
        }
        switch await agent.route(update) {
        case .ignore:
            return
        case .pairing(let chatId, let senderId):
            await sendPlain(chatId: chatId, AgentActor.pairingText(senderId: senderId))
            return
        case .deliver(let routed):
            switch await agent.planReply(for: routed) {
            case .plain(let reply):
                do {
                    if reply.hasPrefix("\(AppIdentity.displayName) v") {
                        _ = try await client.sendMessage(chatId: routed.chatId, text: TelegramFormat.pre(reply), html: true)
                    } else {
                        _ = try await client.sendMessage(chatId: routed.chatId, text: reply)
                    }
                } catch {
                    logger.error("publisher", "sendMessage failed: \(error)")
                }
            case .modelStream(_, let context):
                await handleModelStream(chatId: routed.chatId, context: context)
            }
        }
    }

    /// Owns one conversation turn end to end: streams the model's answer,
    /// and — when it calls a native tool instead of answering (FR-21) —
    /// executes the tool and round-trips the result back to the model for a
    /// final natural-language reply, editing the same Telegram message
    /// throughout. Falls back to the ```run fence exactly as before once the
    /// turn ends in plain text (native tools and the fence are independent:
    /// a wrap-up reply can still contain a fence block).
    private func handleModelStream(chatId: Int64, context: [ChatMessage]) async {
        let model = await agent.currentModel()
        let tools = commandRunner != nil ? await agent.toolDefinitions() : []
        if tools.isEmpty {
            logger.info("agent", "native tools not offered this turn; fence ```run only")
        } else {
            logger.info("agent", "offering \(tools.count) native tools (write_file, run_shell)")
        }
        var messages = context
        var messageId: Int?

        for hop in 0..<Self.maxToolHops {
            let outcome = await publisher.stream(
                chatId: chatId,
                provider: provider,
                model: model,
                messages: messages,
                tools: tools,
                keepAliveSeconds: 0,
                existingMessageId: messageId
            )
            await unloader?.noteUsed()

            switch outcome {
            case .published(let fullText):
                await agent.noteAssistantReply(chatId: chatId, text: fullText)
                // Fence is fallback only: this branch means the hop had no
                // tool_calls. Native tool_calls never reach extractRunCommand.
                await performPostStream(fullText, chatId: chatId, nativeToolsWereOffered: !tools.isEmpty)
                return
            case .toolCallRequested(let calls, let msgId):
                messageId = msgId
                guard let call = calls.first else { return }
                logger.info("agent", "native tool_call: \(call.function.name)")
                if calls.count > 1 {
                    logger.info("agent", "model requested \(calls.count) tool calls at once; running only the first (\(call.function.name))")
                }
                let (toolMessages, shouldContinue) = await performToolCall(call, chatId: chatId, messageId: msgId)
                messages.append(contentsOf: toolMessages)
                if !shouldContinue { return }
            case .failed:
                return
            }
            if hop == Self.maxToolHops - 1, let messageId {
                _ = try? await client.editMessageText(
                    chatId: chatId,
                    messageId: messageId,
                    text: "Слишком много шагов с инструментами подряд — остановлено."
                )
            }
        }
    }

    /// Executes one native tool call (write_file / run_shell) and returns the
    /// `[assistant tool_calls, tool result]` messages to append to history,
    /// plus whether the round-trip should continue this turn. `false` means
    /// execution now waits on a human HITL decision (FR-23): the loop stops
    /// and the callback handler takes over, exactly like the fence path.
    private func performToolCall(_ call: OllamaToolCall, chatId: Int64, messageId: Int) async -> ([ChatMessage], Bool) {
        let assistantCallMessage = ChatMessage.assistantToolCall([call])
        guard let runner = commandRunner else {
            return ([assistantCallMessage, .toolResult(name: call.function.name, content: "исполнение инструментов отключено")], true)
        }
        switch await agent.planToolCall(call) {
        case .invalid(let reason):
            return ([assistantCallMessage, .toolResult(name: call.function.name, content: reason)], true)
        case .writeFile(let path, let content):
            let resultText = await agent.executeWriteFile(path: path, content: content, runner: runner, profileURL: sandboxProfileURL)
            return ([assistantCallMessage, .toolResult(name: call.function.name, content: resultText)], true)
        case .runShell(let plan):
            if plan.requiresConfirmation {
                guard let confirmationId = await agent.storePendingConfirmation(chatId: chatId, command: plan.command) else {
                    _ = try? await client.editMessageText(chatId: chatId, messageId: messageId, text: "Не могу сохранить запрос на подтверждение (БД недоступна) — команда не исполнена.")
                    return ([], false)
                }
                _ = try? await client.editMessageText(chatId: chatId, messageId: messageId, text: "Команда требует подтверждения (см. кнопки ниже).")
                let prompt = TelegramFormat.confirmation(
                    command: plan.command,
                    reason: plan.reason ?? "деструктивная команда"
                )
                do {
                    _ = try await client.sendMessage(
                        chatId: chatId,
                        text: prompt,
                        keyboard: .confirmation(confirmData: "cmd:\(confirmationId):yes", cancelData: "cmd:\(confirmationId):no"),
                        html: true
                    )
                } catch {
                    logger.error("agent", "confirmation message failed: \(error)")
                }
                // Stops the round-trip on purpose: the button flow posts its
                // own plain report on resolution, same as the fence path —
                // no model wrap-up after a HITL-gated tool call.
                return ([], false)
            }
            let report = await agent.executeApprovedCommand(plan.command, runner: runner, profileURL: sandboxProfileURL)
            return ([assistantCallMessage, .toolResult(name: call.function.name, content: report)], true)
        }
    }

    /// Stage 4: after a model reply lands in chat, look for a ```run block.
    /// Only reached when the hop produced text (no `tool_calls`). If native
    /// tools were on the request and the model still emitted a fence, this is
    /// the documented fallback — not a competing first-choice path.
    private func performPostStream(_ reply: String, chatId: Int64, nativeToolsWereOffered: Bool = false) async {
        guard commandRunner != nil else { return }
        guard case .execute(let plan) = await agent.postStreamAction(for: reply) else { return }
        if nativeToolsWereOffered {
            logger.info("agent", "fence ```run fallback (native tools offered but unused this hop)")
        } else {
            logger.info("agent", "fence ```run")
        }

        if plan.requiresConfirmation {
            // HITL gate (FR-23): store the request and attach buttons.
            guard let confirmationId = await agent.storePendingConfirmation(chatId: chatId, command: plan.command) else {
                await sendPlain(chatId: chatId, "Не могу сохранить запрос на подтверждение (БД недоступна) — команда не исполнена.")
                return
            }
            let prompt = TelegramFormat.confirmation(
                command: plan.command,
                reason: plan.reason ?? "деструктивная команда"
            )
            do {
                _ = try await client.sendMessage(
                    chatId: chatId,
                    text: prompt,
                    keyboard: .confirmation(confirmData: "cmd:\(confirmationId):yes", cancelData: "cmd:\(confirmationId):no"),
                    html: true
                )
            } catch {
                logger.error("agent", "confirmation message failed: \(error)")
            }
            return
        }

        let report = await agent.executeApprovedCommand(plan.command, runner: commandRunner!, profileURL: sandboxProfileURL)
        await sendHTML(chatId: chatId, TelegramFormat.shell(report))
    }

    /// HITL button press: validate, consume the request, run or decline.
    private func handleCallback(_ callback: TgCallbackQuery) async {
        guard let data = callback.data, data.hasPrefix("cmd:") else { return }
        let parts = data.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let id = Int64(parts[1]) else { return }
        let approve = parts[2] == "yes"
        guard let message = callback.message else {
            _ = try? await client.answerCallbackQuery(callbackQueryId: callback.id, text: "Нет контекста сообщения")
            return
        }
        let resolution = await agent.resolveConfirmation(
            id: id,
            chatId: message.chat.id,
            senderId: callback.from.id,
            approve: approve
        )
        switch resolution {
        case .approved(let command):
            _ = try? await client.answerCallbackQuery(callbackQueryId: callback.id, text: "Выполняю…")
            if let runner = commandRunner {
                let report = await agent.executeApprovedCommand(command, runner: runner, profileURL: sandboxProfileURL)
                await sendHTML(chatId: message.chat.id, TelegramFormat.shell(report))
            } else {
                await sendPlain(chatId: message.chat.id, "Исполнение команд отключено.")
            }
        case .cancelled:
            _ = try? await client.answerCallbackQuery(callbackQueryId: callback.id, text: "Отменено")
            await sendPlain(chatId: message.chat.id, "Команда отменена.")
        case .ignored:
            _ = try? await client.answerCallbackQuery(callbackQueryId: callback.id, text: "Запрос не найден или истёк")
        }
    }

    private func sendPlain(chatId: Int64, _ text: String) async {
        do {
            _ = try await client.sendMessage(chatId: chatId, text: text)
        } catch {
            logger.error("publisher", "sendMessage failed: \(error)")
        }
    }

    private func sendHTML(chatId: Int64, _ html: String) async {
        do {
            _ = try await client.sendMessage(chatId: chatId, text: html, html: true)
        } catch {
            logger.error("publisher", "sendMessage failed: \(error)")
        }
    }

    /// kv is canonical once the database exists; the JSON file is a read fallback
    /// (legacy import) and a write fallback when kv is unavailable.
    private func currentOffset() async -> Int? {
        if let database {
            do {
                if let raw = try await database.getValue(forKey: Self.offsetKey),
                   let offset = Int(raw) {
                    return offset
                }
            } catch {
                logger.error("listener", "kv read failed, falling back to file: \(error)")
            }
        }
        return state.get(Self.offsetKey).flatMap(Int.init)
    }

    private func persistOffset(_ updateId: Int) async {
        // Offset for the next poll is last_update_id + 1; persist immediately
        // so a crash never re-processes acknowledged updates.
        let value = String(updateId + 1)
        var persisted = false
        if let database {
            do {
                try await database.setValue(value, forKey: Self.offsetKey)
                persisted = true
            } catch {
                logger.error("listener", "failed to persist offset to kv: \(error)")
            }
        }
        if !persisted {
            do {
                try state.set(Self.offsetKey, value)
            } catch {
                logger.error("listener", "failed to persist offset: \(error)")
            }
        }
    }

    private func sleep(seconds: TimeInterval) async {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            // Cancelled during sleep: exit the loop on next check.
        }
    }
}
