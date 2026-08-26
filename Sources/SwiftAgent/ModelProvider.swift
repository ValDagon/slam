import Foundation

/// Provider-agnostic streaming chat completion (FR-16).
/// v1 has a single Ollama implementation; the seam keeps the daemon core
/// swappable for future providers without rewriting routing/publishing.
protocol ModelProvider: Sendable {
    /// Streams assistant deltas; the final chunk carries full text and stats.
    /// `tools` is the native tool-calling catalog (FR-21); pass `[]` for the
    /// fence-marker-only fallback path.
    func streamChat(
        model: String,
        messages: [ChatMessage],
        tools: [OllamaToolDefinition],
        keepAliveSeconds: Int
    ) -> AsyncThrowingStream<ChatDelta, Error>
}

extension ModelProvider {
    /// Convenience overload for the many call sites that never pass tools
    /// (idle-unloader summaries, compression, existing tests).
    func streamChat(
        model: String,
        messages: [ChatMessage],
        keepAliveSeconds: Int
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        streamChat(model: model, messages: messages, tools: [], keepAliveSeconds: keepAliveSeconds)
    }
}

struct ChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
    /// Present only on assistant messages that requested a tool call
    /// (native tools, FR-21); echoed back verbatim in the follow-up turn.
    var toolCalls: [OllamaToolCall]?
    /// Present only on `role: "tool"` result messages: which function ran.
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    init(role: String, content: String, toolCalls: [OllamaToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    static func system(_ text: String) -> ChatMessage { .init(role: "system", content: text) }
    static func user(_ text: String) -> ChatMessage { .init(role: "user", content: text) }
    static func assistant(_ text: String) -> ChatMessage { .init(role: "assistant", content: text) }
    /// Assistant turn that requested tool call(s); content stays empty per
    /// the Ollama contract (see ToolCalling.swift).
    static func assistantToolCall(_ calls: [OllamaToolCall]) -> ChatMessage {
        .init(role: "assistant", content: "", toolCalls: calls)
    }
    /// Tool result fed back to the model for the follow-up turn.
    static func toolResult(name: String, content: String) -> ChatMessage {
        .init(role: "tool", content: content, toolName: name)
    }
}

enum ChatDelta: Sendable {
    case delta(String)
    case final(text: String, evalCount: Int?)
    /// The model requested tool call(s) instead of (or before) text content.
    case toolCalls([OllamaToolCall])
}
