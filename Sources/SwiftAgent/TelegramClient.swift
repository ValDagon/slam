import Foundation

enum TelegramAPIError: Error {
    /// Second active getUpdates poller detected (HTTP 409 semantics).
    case conflict
    /// Rate limited; carries retry_after seconds when Telegram provides it.
    case rateLimit(retryAfter: Int?)
    /// Any other non-ok API response with its error_code (when present).
    case apiError(code: Int?, description: String?)
    /// Transport-level failure below HTTP (URLError and friends).
    case transport(Error)
}

extension TelegramAPIError: CustomStringConvertible {
    var description: String {
        switch self {
        case .conflict:
            return "409 conflict: second getUpdates instance detected"
        case .rateLimit(let retryAfter):
            return "rate limited (retry_after=\(retryAfter.map(String.init) ?? "?"))"
        case .apiError(let code, let description):
            return "telegram api error \(code.map(String.init) ?? "-"): \(description ?? "unknown")"
        case .transport(let error):
            return "transport error: \(error)"
        }
    }
}

/// Thin Telegram Bot API client over native URLSession.
///
/// Long polling uses getUpdates with timeout=30; requests carry a slightly larger
/// client-side timeout so the server closes the poll before URLSession gives up.
struct TelegramClient: Sendable {
    let token: String
    let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    static func apiBase(token: String) -> URL {
        URL(string: "https://api.telegram.org/bot\(token)")!
    }

    // MARK: - Methods used by the daemon

    func getMe() async throws -> TgUser {
        try await call("getMe", query: [])
    }

    func getUpdates(offset: Int?, timeoutSeconds: Int = 30) async throws -> [TgUpdate] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "timeout", value: String(timeoutSeconds)),
            URLQueryItem(name: "allowed_updates", value: #"["message","callback_query"]"#),
        ]
        if let offset {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        return try await call(
            "getUpdates",
            query: query,
            requestTimeout: TimeInterval(timeoutSeconds + 15)
        )
    }

    @discardableResult
    func deleteWebhook(dropPendingUpdates: Bool = false) async throws -> Bool {
        let query = dropPendingUpdates ? [URLQueryItem(name: "drop_pending_updates", value: "true")] : []
        return try await call("deleteWebhook", query: query)
    }

    func getWebhookInfo() async throws -> WebhookInfo {
        try await call("getWebhookInfo", query: [])
    }

    struct WebhookInfo: Codable, Sendable, Equatable {
        let url: String
        let pendingUpdateCount: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case pendingUpdateCount = "pending_update_count"
        }
    }

    func sendMessage(chatId: Int64, text: String, keyboard: InlineKeyboard? = nil, html: Bool = false) async throws -> TgMessage {
        struct Payload: Encodable {
            let chat_id: Int64
            let text: String
            let parse_mode: String
            let disable_web_page_preview: Bool
            let reply_markup: InlineKeyboard?
        }
        let body = Payload(
            chat_id: chatId,
            text: html ? text : TelegramFormat.plain(text),
            parse_mode: TelegramFormat.parseMode,
            disable_web_page_preview: true,
            reply_markup: keyboard
        )
        let encoder = JSONEncoder()
        var request = URLRequest(url: Self.apiBase(token: token).appendingPathComponent("sendMessage"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    /// Confirms a callback button press so the user sees the loading state end.
    @discardableResult
    func answerCallbackQuery(callbackQueryId: String, text: String? = nil) async throws -> Bool {
        struct Payload: Encodable {
            let callback_query_id: String
            let text: String?
        }
        let body = Payload(callback_query_id: callbackQueryId, text: text)
        var request = URLRequest(url: Self.apiBase(token: token).appendingPathComponent("answerCallbackQuery"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// Shows the native Telegram "typing…" status. It expires in ~5 seconds;
    /// callers refresh while generation is still in progress.
    @discardableResult
    func sendChatAction(chatId: Int64, action: String = "typing") async throws -> Bool {
        struct Payload: Encodable {
            let chat_id: Int64
            let action: String
        }
        let body = Payload(chat_id: chatId, action: action)
        var request = URLRequest(url: Self.apiBase(token: token).appendingPathComponent("sendChatAction"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    @discardableResult
    func editMessageText(chatId: Int64, messageId: Int, text: String, html: Bool = false) async throws -> TgMessage {
        struct Payload: Encodable {
            let chat_id: Int64
            let message_id: Int
            let text: String
            let parse_mode: String
        }
        let body = Payload(
            chat_id: chatId,
            message_id: messageId,
            text: html ? text : TelegramFormat.plain(text),
            parse_mode: TelegramFormat.parseMode
        )
        var request = URLRequest(url: Self.apiBase(token: token).appendingPathComponent("editMessageText"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    // MARK: - Plumbing

    private func call<Result: Codable & Sendable>(
        _ method: String,
        query: [URLQueryItem],
        requestTimeout: TimeInterval = 60
    ) async throws -> Result {
        var components = URLComponents(url: Self.apiBase(token: token).appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = requestTimeout
        return try await perform(request)
    }

    private func perform<Result: Codable & Sendable>(_ request: URLRequest) async throws -> Result {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TelegramAPIError.transport(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramAPIError.transport(URLError(.badServerResponse))
        }
        let decoder = JSONDecoder()
        do {
            let envelope = try decoder.decode(TgApiResponse<Result>.self, from: data)
            if envelope.ok, let result = envelope.result {
                return result
            }
            if envelope.errorCode == 409 || httpResponse.statusCode == 409 {
                throw TelegramAPIError.conflict
            }
            if envelope.errorCode == 429 || httpResponse.statusCode == 429 {
                throw TelegramAPIError.rateLimit(retryAfter: Self.retryAfter(envelope: envelope, response: httpResponse))
            }
            throw TelegramAPIError.apiError(
                code: envelope.errorCode ?? httpResponse.statusCode,
                description: envelope.description
            )
        } catch let error as TelegramAPIError {
            throw error
        } catch is DecodingError {
            // Non-JSON or unexpected shape: fall back to status-code based mapping.
            switch httpResponse.statusCode {
            case 409: throw TelegramAPIError.conflict
            case 429: throw TelegramAPIError.rateLimit(retryAfter: Self.retryAfterHeader(httpResponse))
            default: throw TelegramAPIError.apiError(code: httpResponse.statusCode, description: nil)
            }
        } catch {
            throw TelegramAPIError.transport(error)
        }
    }

    /// retry_after from the body wins; the HTTP Retry-After header (whole seconds)
    /// is the fallback for responses where Telegram omits parameters.
    private static func retryAfter(envelope: TgApiResponse<some Any>, response: HTTPURLResponse) -> Int? {
        envelope.parameters?.retryAfter ?? retryAfterHeader(response)
    }

    private static func retryAfterHeader(_ response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }
}
