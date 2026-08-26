import Foundation

/// Extraction of ```run fenced blocks and destructive-command classification.
///
/// The fence marker is the v1 fallback channel (FR-21): the model writes
///
///     ```run
///     ls -la
///     ```
///
/// and the daemon executes the first block after the HITL gate (FR-23).
enum CommandSafety: Sendable {
    struct Plan: Sendable, Equatable {
        var command: String
        /// True when a destructive pattern matched: execution waits for the button.
        var requiresConfirmation: Bool
        /// Human-readable reason when confirmation is required.
        var reason: String?
    }

    // MARK: - Fence marker

    static let fenceOpen = "```run"
    static let codeFence = "```"

    /// First ```run block in the text, or nil. Content up to the closing fence;
    /// unterminated blocks are rejected on purpose (half-pasted commands).
    static func extractRunCommand(from text: String) -> String? {
        guard let openRange = text.range(of: fenceOpen) else { return nil }
        let rest = text[openRange.upperBound...]
        guard let closeRange = rest.range(of: codeFence) else { return nil }
        let body = String(rest[..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Strips run fences so the raw block never leaks into chat context.
    static func strippingRunBlocks(from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while let openRange = text.range(of: fenceOpen, range: cursor..<text.endIndex) {
            result += text[cursor..<openRange.lowerBound]
            let afterOpen = openRange.upperBound
            if let closeRange = text.range(of: codeFence, range: afterOpen..<text.endIndex) {
                cursor = closeRange.upperBound
            } else {
                cursor = afterOpen
                break
            }
        }
        result += text[cursor...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Destructive classification

    /// Default patterns overridable by config (FR-23). Word-boundary regexes
    /// anchored at token starts; case-insensitive.
    nonisolated static let defaultPatterns: [String] = [
        #"\brm\b"#,
        #"\brmdir\b"#,
        #"\bmkfs(\.\w+)?\b"#,
        #"\bdd\b"#,
        #"\bshutdown\b"#,
        #"\breboot\b"#,
        #"\bhalt\b"#,
        #"\bpkill\b"#,
        #"\bkillall\b"#,
        #"\bchmod\b"#,
        #"\bchown\b"#,
        #">\s*/dev/sd"#,
        #"git\s+push\s+.*--force"#,
        #"drop\s+(table|database)\b"#,
    ]

    static func plan(command: String, extraPatterns: [String] = []) -> Plan {
        let patterns = defaultPatterns + extraPatterns
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(command.startIndex..., in: command)
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return Plan(
                    command: command,
                    requiresConfirmation: true,
                    reason: "совпадает с деструктивным паттерном `\(pattern)`"
                )
            }
        }
        return Plan(command: command, requiresConfirmation: false, reason: nil)
    }

    // MARK: - Sandbox scope advisory (FR-22)

    /// Soft warning when the command likely scans outside WORKING_DIR (~ / $HOME).
    /// Does not block execution — the model/system_prompt should prefer workspace-
    /// scoped finds; this only clarifies empty/denied outcomes to the human.
    static func sandboxScopeWarning(command: String, workingDir: String) -> String? {
        let patterns: [String] = [
            #"\b(find|du|ls|tree|fd)\s+(~(\s|/|$)|\$HOME\b)"#,
            #"\b(find|du|ls|tree|fd)\s+/Users/[^/\s]+(\s|$)"#,
        ]
        let range = NSRange(command.startIndex..., in: command)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return "подсказка: песочница читает только workspace (\(workingDir)); полный ~ закрыт (FR-22). Сузьте путь (`.` или согласованный каталог)."
            }
        }
        return nil
    }

    /// Heuristic for the post-failure hint (FR-22): redirection or common
    /// write/create commands imply the denial is the write-scope rule
    /// (WORKING_DIR/tmp only), not the read-scope one. Without this check the
    /// generic "reads only within workspace" hint is actively misleading for
    /// `echo x > file.txt` style denials — the read of workspace succeeds,
    /// only the write to the non-tmp path is denied.
    static func looksLikeWriteAttempt(_ command: String) -> Bool {
        let patterns: [String] = [
            #"(?<![>&])>{1,2}(?!&)"#,
            #"\btee\b"#,
            #"\bmkdir\b"#,
            #"\btouch\b"#,
            #"\bcp\b"#,
            #"\bmv\b"#,
            #"\bdd\b.*\bof="#,
            #"\bsed\b.*-i\b"#,
        ]
        let range = NSRange(command.startIndex..., in: command)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
