import Foundation

/// Deterministic Telegram HTML (not model-authored). Callers that send
/// daemon-produced transcripts wrap them here; model replies stay `plain`
/// so the LLM cannot inject markup.
enum TelegramFormat {
    static let parseMode = "HTML"

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func plain(_ text: String) -> String { escape(text) }

    static func pre(_ text: String) -> String {
        "<pre>\(escape(text))</pre>"
    }

    /// `AgentActor.render` transcript: body in `<pre>`, trailing `подсказка:`
    /// lines as italic after the block.
    static func shell(_ transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body: [String] = []
        var hints: [String] = []
        for line in lines {
            if line.hasPrefix("подсказка:") {
                hints.append(line)
            } else {
                body.append(line)
            }
        }
        var parts: [String] = []
        let bodyText = body.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !bodyText.isEmpty {
            parts.append(pre(bodyText))
        }
        for hint in hints {
            parts.append("<i>\(escape(hint))</i>")
        }
        return parts.joined(separator: "\n")
    }

    static func confirmation(command: String, reason: String) -> String {
        "Требуется подтверждение (10 минут):\n<code>\(escape("$ \(command)"))</code>\nПричина: \(escape(reason))"
    }
}
