import Foundation

/// Publishes a streamed answer to one Telegram message via editMessageText.
///
/// Telegram rate-limits edits, so deltas are coalesced on a time throttle
/// (FR-9): an edit goes out at most once per interval carrying everything
/// accumulated so far; the final edit always delivers the complete text.
///
/// While tokens are still arriving the visible text keeps a trailing cursor
/// and `sendChatAction(typing)` is refreshed so the chat does not look finished.
struct StreamingTelegramPublisher: Sendable {
    let client: TelegramClient
    let logger: FileLogger
    /// Minimum spacing between edits in seconds.
    var minEditInterval: TimeInterval = 1.5
    /// How often to refresh Telegram's "typing…" indicator. `nil` disables it
    /// (tests). Telegram expires the indicator after ~5 s, so production uses 4 s.
    var typingRefreshInterval: TimeInterval? = 4

    /// Placeholder shown until the first throttled edit lands.
    static let thinkingPlaceholder = "⏳ думаю…"
    /// Shown when the model requests a native tool call instead of text
    /// (FR-21): replaces the raw tool-call JSON that would otherwise leak.
    static let toolRunningPrefix = "⏳ выполняю "
    /// Trailing mark on in-progress edits; stripped from the final text.
    static let progressCursor = " ▍"
    static let telegramTextLimit = 4096

    enum Outcome: Sendable {
        case published(fullText: String)
        /// The model called tool(s) instead of answering; the placeholder
        /// message (`messageId`) stays open for the caller to keep editing
        /// across the tool round-trip.
        case toolCallRequested(calls: [OllamaToolCall], messageId: Int)
        case failed(Error)
    }

    @discardableResult
    func stream(
        chatId: Int64,
        provider: ModelProvider,
        model: String,
        messages: [ChatMessage],
        tools: [OllamaToolDefinition] = [],
        keepAliveSeconds: Int,
        existingMessageId: Int? = nil
    ) async -> Outcome {
        do {
            return try await run(
                chatId: chatId,
                provider: provider,
                model: model,
                messages: messages,
                tools: tools,
                keepAliveSeconds: keepAliveSeconds,
                existingMessageId: existingMessageId
            )
        } catch {
            logger.error("publisher", "stream failed: \(error)")
            await sendFallback(chatId: chatId, error: error)
            return .failed(error)
        }
    }

    private func run(
        chatId: Int64,
        provider: ModelProvider,
        model: String,
        messages: [ChatMessage],
        tools: [OllamaToolDefinition],
        keepAliveSeconds: Int,
        existingMessageId: Int?
    ) async throws -> Outcome {
        let typing = startTypingHeartbeat(chatId: chatId)
        defer { typing.cancel() }

        let placeholder: Placeholder
        if let existingMessageId {
            placeholder = Placeholder(messageId: existingMessageId)
        } else {
            placeholder = try await sendPlaceholder(chatId: chatId)
        }
        var lastEdit = Date()
        var accumulated = ""

        for try await delta in provider.streamChat(
            model: model,
            messages: messages,
            tools: tools,
            keepAliveSeconds: keepAliveSeconds
        ) {
            switch delta {
            case .delta(let piece):
                accumulated += piece
                if Date().timeIntervalSince(lastEdit) >= minEditInterval {
                    await editSafely(
                        messageId: placeholder.messageId,
                        chatId: chatId,
                        text: Self.inProgressText(accumulated)
                    )
                    lastEdit = Date()
                }
            case .toolCalls(let calls):
                typing.cancel()
                let label = calls.first?.function.name ?? "инструмент"
                await editFinal(messageId: placeholder.messageId, chatId: chatId, text: "\(Self.toolRunningPrefix)\(label)…")
                return .toolCallRequested(calls: calls, messageId: placeholder.messageId)
            case .final(let text, _):
                // Guarantee the complete text regardless of throttle state.
                if !text.isEmpty && text != accumulated { accumulated = text }
                typing.cancel()
                await editFinal(messageId: placeholder.messageId, chatId: chatId, text: accumulated)
                return .published(fullText: accumulated)
            }
        }

        // Stream ended without a final marker.
        if accumulated.isEmpty { throw OllamaError.malformedStream("empty stream") }
        typing.cancel()
        await editFinal(messageId: placeholder.messageId, chatId: chatId, text: accumulated)
        return .published(fullText: accumulated)
    }

    /// Incomplete replies keep a trailing cursor so they are not mistaken for
    /// a finished message between throttled edits.
    static func inProgressText(_ text: String) -> String {
        let mark = progressCursor
        if text.count + mark.count <= telegramTextLimit {
            return text + mark
        }
        return String(text.prefix(telegramTextLimit))
    }

    private struct Placeholder: Sendable {
        let messageId: Int
    }

    private func sendPlaceholder(chatId: Int64) async throws -> Placeholder {
        let message = try await client.sendMessage(chatId: chatId, text: Self.thinkingPlaceholder)
        return Placeholder(messageId: message.messageId)
    }

    private func startTypingHeartbeat(chatId: Int64) -> Task<Void, Never> {
        guard let interval = typingRefreshInterval, interval > 0 else {
            return Task {}
        }
        let client = self.client
        let logger = self.logger
        return Task {
            while !Task.isCancelled {
                do {
                    _ = try await client.sendChatAction(chatId: chatId)
                } catch {
                    logger.debug("publisher", "sendChatAction failed: \(error)")
                }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    private func editSafely(messageId: Int, chatId: Int64, text: String) async {
        guard let backoff = await editWithRetry(messageId: messageId, chatId: chatId, text: text) else { return }
        // 429 with Retry-After: sleep and retry exactly once for intermediate edits.
        do {
            try await Task.sleep(for: .seconds(backoff))
            _ = await editWithRetry(messageId: messageId, chatId: chatId, text: text)
        } catch {
            // Cancelled mid-backoff; next delta or the final edit will catch up.
        }
    }

    /// Returns retry-after seconds when rate limited (after recording the issue),
    /// nil when the edit went through or failed unrecoverably.
    private func editWithRetry(messageId: Int, chatId: Int64, text: String) async -> Double? {
        do {
            try await client.editMessageText(chatId: chatId, messageId: messageId, text: text)
            return nil
        } catch TelegramAPIError.rateLimit(let retryAfter) {
            logger.info("publisher", "edit rate limited, backing off \(retryAfter.map(String.init) ?? "5")s")
            return Double(retryAfter ?? 5)
        } catch TelegramAPIError.apiError(let code, _) where code == 400 {
            // "message is not modified" happens when the throttled content equals
            // what Telegram already shows; safe to ignore for intermediate edits.
            logger.debug("publisher", "edit rejected with 400 (likely not-modified), skipping")
            return nil
        } catch {
            logger.error("publisher", "edit failed: \(error)")
            return nil
        }
    }

    private func editFinal(messageId: Int, chatId: Int64, text: String) async {
        _ = await editWithRetry(messageId: messageId, chatId: chatId, text: text)
    }

    private func sendFallback(chatId: Int64, error: Error) async {
        let text = "Ошибка генерации: \(error)"
        do {
            _ = try await client.sendMessage(chatId: chatId, text: text)
        } catch {
            logger.error("publisher", "fallback message failed: \(error)")
        }
    }
}
