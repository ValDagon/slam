import Foundation

/// Native Ollama tool-calling support (FR-21 half two): request/response types
/// for `POST /api/chat` `tools` + `tool_calls`, plus the tool catalog and the
/// `write_file` path-safety validator.
///
/// Contract confirmed against docs.ollama.com/api/chat, docs.ollama.com/capabilities/tool-calling
/// and github.com/ollama/ollama/blob/main/docs/api.md (checked 2026-08-26):
/// - Request: `tools: [{type: "function", function: {name, description, parameters: <JSON Schema>}}]`.
/// - Response message carries `tool_calls: [{function: {name, arguments: <JSON object>}}]`;
///   `arguments` is already a parsed JSON object, not a string (unlike OpenAI).
/// - Streaming: the tool-call chunk arrives with `done: false` and empty `content`,
///   followed by a final `done: true` chunk with no further content — there is no
///   incremental/partial streaming of the tool call itself.
/// - Follow-up turn: append the assistant's tool_calls message verbatim, then a
///   `{role: "tool", tool_name: "<fn>", content: "<result>"}` message, and call
///   `/api/chat` again (same `tools` list) to get the final natural-language reply.
/// - qwen2.5 (Ollama library tag `qwen2.5:7b`) ships a Hermes-style `<tool_call>`
///   template and is documented by Qwen as tool-call capable under Ollama.

/// Minimal open-ended JSON value: tool parameter schemas are arbitrary JSON
/// Schema, and `tool_calls[].function.arguments` is an arbitrary JSON object —
/// neither fits a fixed Codable shape.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Request: tool definitions

/// `ToolDefinition` per the Ollama OpenAPI schema: `{type: "function", function: {...}}`.
struct OllamaToolDefinition: Encodable, Sendable {
    struct FunctionSpec: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: JSONValue
    }
    var type: String = "function"
    let function: FunctionSpec

    init(function: FunctionSpec) {
        self.function = function
    }
}

// MARK: - Response: tool calls

/// `ToolCall` as returned in `message.tool_calls` and echoed back verbatim in
/// the assistant history message for the follow-up turn.
struct OllamaToolCall: Codable, Sendable, Equatable {
    struct FunctionCall: Codable, Sendable, Equatable {
        let name: String
        let arguments: [String: JSONValue]
    }
    let function: FunctionCall
}

// MARK: - Tool catalog exposed to the model

/// Static tool catalog (FR-21). Both tools funnel through the exact same
/// sandbox-exec + ProcessRunner path as the ```run fence fallback — no
/// separate execution mechanism, no separate HITL mechanism.
enum ToolCatalog {
    static let writeFile = OllamaToolDefinition(function: .init(
        name: "write_file",
        description: """
        Записать текст в файл внутри песочницы. Разрешена запись только \
        в каталог tmp/ рабочей директории (WORKING_DIR/tmp) — всё остальное \
        дерево read-only. path — путь ОТНОСИТЕЛЬНО tmp/, без ведущего / и без \
        .. (например "notes/todo.txt" создаст tmp/notes/todo.txt). content — \
        полное содержимое файла (UTF-8 текст, до 64 КБ), перезаписывает файл целиком.
        """,
        parameters: [
            "type": "object",
            "required": ["path", "content"],
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Относительный путь внутри tmp/, без .. и без ведущего /",
                ],
                "content": [
                    "type": "string",
                    "description": "Полное содержимое файла (UTF-8)",
                ],
            ],
        ]
    ))

    static let runShell = OllamaToolDefinition(function: .init(
        name: "run_shell",
        description: """
        Выполнить одну shell-команду (zsh -c) в той же песочнице, что и \
        ```run: чтение — рабочая директория и системные пути, запись — \
        только tmp/, сеть отключена. Деструктивные команды (rm, dd, chmod, \
        shutdown и т.п.) требуют подтверждения человека кнопкой в чате перед \
        исполнением — вызови инструмент один раз, результат придёт после \
        подтверждения или отказа.
        """,
        parameters: [
            "type": "object",
            "required": ["command"],
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Команда для выполнения через zsh -c",
                ],
            ],
        ]
    ))

    static let all: [OllamaToolDefinition] = [writeFile, runShell]
}

// MARK: - write_file path safety (FR-22 parity)

/// Validates and executes the `write_file` tool. Two independent barriers
/// guard WORKING_DIR/tmp: this realpath-based containment check (Swift side)
/// and the SBPL `file-write*` rule (OS side, `ProcessRunner`/`SandboxProfile`).
/// A bug in either layer alone cannot leak a write outside the sandbox.
enum FileWriteTool {
    static let maxContentBytes = 64 * 1024

    enum PathError: Error, CustomStringConvertible, Equatable {
        case empty
        case absoluteOrHome(String)
        case traversal(String)
        case unresolvable(String)
        case escapesSandbox(String)

        var description: String {
            switch self {
            case .empty:
                return "путь не может быть пустым"
            case .absoluteOrHome(let path):
                return "абсолютные пути и ~ запрещены: \(path)"
            case .traversal(let path):
                return "переходы через .. запрещены: \(path)"
            case .unresolvable(let path):
                return "не удалось разрешить путь: \(path)"
            case .escapesSandbox(let path):
                return "путь выходит за пределы tmp/: \(path)"
            }
        }
    }

    /// Catalog path is already relative to WORKING_DIR/tmp. Models often pass
    /// `tmp/foo` because prompts say "write under tmp/" — a leading `tmp/`
    /// component would otherwise nest as tmp/tmp/foo. Only the first component
    /// is stripped; `tmp/tmp/x` still lands at tmp/tmp/x.
    static func stripRedundantTmpPrefix(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.first == "tmp" else { return path }
        return parts.dropFirst().joined(separator: "/")
    }

    /// `tmpDir` must already exist (DaemonMain creates WORKING_DIR/tmp at boot).
    /// Rejects, in order: empty input, absolute/`~` paths, any literal `..`
    /// path component, then canonicalizes the destination's parent directory
    /// and re-checks containment — this last step is what catches a symlink
    /// planted inside tmp/ that points outside the sandbox.
    static func resolveSafePath(_ rawPath: String, tmpDir: String) -> Result<String, PathError> {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .failure(.absoluteOrHome(trimmed))
        }
        let relative = stripRedundantTmpPrefix(trimmed)
        guard !relative.isEmpty else { return .failure(.empty) }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." }) {
            return .failure(.traversal(trimmed))
        }
        guard let canonicalTmp = canonicalPath(tmpDir) else {
            return .failure(.unresolvable(tmpDir))
        }
        let lexicalCandidate = (canonicalTmp as NSString).appendingPathComponent(relative)
        let parent = (lexicalCandidate as NSString).deletingLastPathComponent
        let leaf = (lexicalCandidate as NSString).lastPathComponent
        guard !leaf.isEmpty else { return .failure(.empty) }
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard let canonicalParent = canonicalPath(parent) else {
            return .failure(.unresolvable(parent))
        }
        guard canonicalParent == canonicalTmp || canonicalParent.hasPrefix(canonicalTmp + "/") else {
            return .failure(.escapesSandbox(canonicalParent))
        }
        return .success((canonicalParent as NSString).appendingPathComponent(leaf))
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Classic single-quote shell escaping: wrap in `'...'`, turn each
    /// embedded `'` into `'\''`. Safe for arbitrary bytes/newlines/`%`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `printf '%s'` does not reinterpret escapes/format specifiers inside
    /// the substituted argument, so content is written byte-for-byte with no
    /// trailing newline added.
    static func writeCommand(content: String, absolutePath: String) -> String {
        "printf '%s' \(shellQuote(content)) > \(shellQuote(absolutePath))"
    }
}
