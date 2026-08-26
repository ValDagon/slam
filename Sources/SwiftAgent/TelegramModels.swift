import Foundation

struct TgUser: Codable, Sendable, Equatable {
    let id: Int64
    let isBot: Bool?
    let firstName: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case username
    }
}

struct TgChat: Codable, Sendable, Equatable {
    let id: Int64
    let type: String?
}

struct TgMessage: Codable, Sendable, Equatable {
    let messageId: Int
    let from: TgUser?
    let chat: TgChat
    let date: Int
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from
        case chat
        case date
        case text
    }
}

struct TgCallbackQuery: Codable, Sendable, Equatable {
    let id: String
    let from: TgUser
    let data: String?
    /// The message the button is attached to; present for inline keyboards in chats.
    let message: TgMessage?

    enum CodingKeys: String, CodingKey {
        case id
        case from
        case data
        case message
    }
}

/// One Telegram update. Only message and callback_query are requested via allowed_updates.
struct TgUpdate: Codable, Sendable, Equatable {
    let updateId: Int
    let message: TgMessage?
    let callbackQuery: TgCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }

    /// Text payload regardless of update kind.
    var effectiveText: String? {
        message?.text ?? callbackQuery?.data
    }

    var chatId: Int64? {
        message?.chat.id
    }

    var senderId: Int64? {
        message?.from?.id ?? callbackQuery?.from.id
    }
}

/// Standard Telegram API response envelope: {"ok": bool, "result": ..., "description": ...}.
struct TgApiResponse<Result: Codable & Sendable>: Codable, Sendable {
    let ok: Bool
    let result: Result?
    let description: String?
    let errorCode: Int?
    let parameters: TgResponseParameters?

    enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
        case errorCode = "error_code"
        case parameters
    }
}

struct TgResponseParameters: Codable, Sendable, Equatable {
    let retryAfter: Int?

    enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}

// MARK: - Inline keyboards (stage 4, FR-23)

/// Minimal reply markup: rows of callback buttons.
struct InlineKeyboard: Encodable, Sendable, Equatable {
    struct Button: Encodable, Sendable, Equatable {
        let text: String
        let callback_data: String

        static func confirm(_ data: String) -> Button { .init(text: "✅ Выполнить", callback_data: data) }
        static func cancel(_ data: String) -> Button { .init(text: "❌ Отмена", callback_data: data) }
    }

    let inline_keyboard: [[Button]]

    static func confirmation(confirmData: String, cancelData: String) -> InlineKeyboard {
        .init(inline_keyboard: [[.confirm(confirmData), .cancel(cancelData)]])
    }
}
