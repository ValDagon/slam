import Foundation

/// Allowlist gate outcome before message handling (FR-7).
enum IngressDecision: Sendable, Equatable {
  case deliver(RoutedUpdate)
  /// Unknown user sent /start — offer pairing with their Telegram ID.
  case pairing(chatId: Int64, senderId: Int64)
  /// Drop silently (no chat id, empty text, or stranger non-/start).
  case ignore
}

/// One routed user-facing update.
struct RoutedUpdate: Sendable, Equatable {
    let chatId: Int64
    let senderId: Int64
    let text: String
    /// True when this update was persisted into the state store already.
    let isCommand: Bool
}

/// Parses raw text into a bot command or plain conversational text.
struct CommandParser: Sendable {
    enum Parsed: Equatable, Sendable {
        case start
        case help
        case status
        case allow(id: Int64)
        case deny(id: Int64)
        case model(name: String)
        case unknownCommand(String)
        case plain(text: String)

        static func from(_ raw: String) -> Parsed {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return .plain(text: raw) }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { return .plain(text: raw) }
            // Strip @botname suffix that Telegram appends in groups.
            let name = head.dropFirst().split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let arg = parts.count > 1 ? String(parts[1]) : nil
            switch name {
            case "start": return .start
            case "help": return .help
            case "status": return .status
            case "allow":
                if let arg, let id = Int64(arg) { return .allow(id: id) }
                return .unknownCommand(trimmed)
            case "deny":
                if let arg, let id = Int64(arg) { return .deny(id: id) }
                return .unknownCommand(trimmed)
            case "model":
                if let arg, !arg.isEmpty { return .model(name: arg) }
                return .unknownCommand(trimmed)
            default: return .unknownCommand(trimmed)
            }
        }
    }
}

/// Result of a HITL button press after the agent validated it.
enum ConfirmationResolution: Sendable, Equatable {
    /// Command approved; carries its database row id and text for logging/audit.
    case approved(command: String)
    case cancelled
    /// Unknown id, foreign chat, or expired request — nothing to do.
    case ignored
}
