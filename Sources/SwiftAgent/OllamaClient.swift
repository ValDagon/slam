import Foundation

enum OllamaError: Error, CustomStringConvertible {
    case http(status: Int)
    case malformedStream(String)
    case transport(Error)

    var description: String {
        switch self {
        case .http(let status): return "ollama http \(status)"
        case .malformedStream(let detail): return "ollama stream malformed: \(detail)"
        case .transport(let error): return "ollama transport: \(error)"
        }
    }
}

/// Native Ollama client over URLSession async APIs (FR-12/FR-13).
///
/// Every chat request carries top-level `"keep_alive": 0`: weights leave VRAM
/// right after the answer (resource budget is a spec requirement). Streaming
/// reads `URLSession.bytes(for:)` line by line; cancellation of the consuming
/// task tears down the underlying request.
struct OllamaClient: ModelProvider, Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func streamChat(
        model: String,
        messages: [ChatMessage],
        tools: [OllamaToolDefinition],
        keepAliveSeconds: Int
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .utility) {
                do {
                    try await runStream(
                        model: model,
                        messages: messages,
                        tools: tools,
                        keepAliveSeconds: keepAliveSeconds,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Unload weights immediately: empty messages + keep_alive 0 (FR-15).
    /// Used by the idle-unloader as a belt-and-braces call even though every
    /// chat request already sends keep_alive: 0.
    func unload(model: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatBody(model: model, messages: [], tools: nil, stream: false, keepAlive: 0)
        )
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaError.http(status: -1) }
            guard http.statusCode == 200 else { throw OllamaError.http(status: http.statusCode) }
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.transport(error)
        }
    }

    // MARK: - NDJSON streaming

    struct StreamChunk: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
            let toolCalls: [OllamaToolCall]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        let message: Message?
        let done: Bool
        let evalCount: Int?

        enum CodingKeys: String, CodingKey {
            case message
            case done
            case evalCount = "eval_count"
        }
    }

    private func runStream(
        model: String,
        messages: [ChatMessage],
        tools: [OllamaToolDefinition],
        keepAliveSeconds: Int,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        // Generation can legitimately take minutes; no artificial ceiling here.
        request.timeoutInterval = .infinity
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatBody(
                model: model,
                messages: messages,
                tools: tools.isEmpty ? nil : tools,
                stream: true,
                keepAlive: keepAliveSeconds
            )
        )

        let dataTask: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (dataTask, response) = try await session.bytes(for: request)
        } catch {
            throw OllamaError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.http(status: -1) }
        guard http.statusCode == 200 else {
            // Error bodies are plain text or JSON; drain a bounded prefix for context.
            var firstBytes = Data()
            for try await byte in dataTask {
                firstBytes.append(byte)
                if firstBytes.count >= 512 { break }
            }
            throw OllamaError.malformedStream("status \(http.statusCode): \(String(decoding: firstBytes, as: UTF8.self))")
        }

        var full = ""
        for try await line in dataTask.lines {
            guard !line.isEmpty, !Task.isCancelled else { continue }
            let chunk: StreamChunk
            do {
                chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(line.utf8))
            } catch {
                // A torn final line must not kill an otherwise complete answer;
                // log-shaped garbage is skipped, only fatal when it precedes any delta.
                if full.isEmpty { throw OllamaError.malformedStream(line) }
                continue
            }
            // Tool-call chunks arrive with empty content and done:false, followed
            // by a contentless done:true chunk — there is no partial streaming of
            // the call itself, so this ends the stream immediately.
            if let calls = chunk.message?.toolCalls, !calls.isEmpty {
                continuation.yield(.toolCalls(calls))
                return
            }
            if let piece = chunk.message?.content, !piece.isEmpty {
                full += piece
                continuation.yield(.delta(piece))
            }
            if chunk.done {
                continuation.yield(.final(text: full, evalCount: chunk.evalCount))
                return
            }
        }
        // Server closed without a done marker: still deliver what we have.
        continuation.yield(.final(text: full, evalCount: nil))
    }

    struct ChatBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        /// Omitted entirely (not even `[]`) when native tools are off (FR-21
        /// fallback): some models/templates react to the mere presence of an
        /// empty tools array, so nil beats an empty list here.
        let tools: [OllamaToolDefinition]?
        let stream: Bool
        let keepAlive: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case tools
            case stream
            case keepAlive = "keep_alive"
        }
    }
}
