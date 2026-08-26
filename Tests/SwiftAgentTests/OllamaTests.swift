import Foundation
import Testing
@testable import SwiftAgent

/// Ollama tests use the shared StubProtocol keyed by port: each test binds a
/// unique localhost port so parallel suites never share response queues.
@Suite struct OllamaStreamTests {
    private func makeClient(port: UInt16) -> OllamaClient {
        OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, session: makeStubbedSession())
    }

    private func ndjson(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func streamsDeltasAndFinal() async throws {
        let ns = "port-45001"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([
            #"{"message":{"role":"assistant","content":"Привет"},"done":false}"#,
            #"{"message":{"role":"assistant","content":", мир"},"done":false}"#,
            #"{"done":true,"eval_count":42}"#,
        ]))))
        let client = makeClient(port: 45_001)

        var deltas: [String] = []
        var finalText: String?
        for try await delta in client.streamChat(model: "m", messages: [.user("hi")], keepAliveSeconds: 0) {
            switch delta {
            case .delta(let piece): deltas.append(piece)
            case .final(let text, _): finalText = text
            case .toolCalls: Issue.record("unexpected tool call")
            }
        }
        #expect(deltas == ["Привет", ", мир"])
        #expect(finalText == "Привет, мир")
    }

    @Test func everyChatRequestCarriesKeepAliveZeroAndModel() async throws {
        let ns = "port-45002"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([#"{"done":true}"#]))))
        let client = makeClient(port: 45_002)

        _ = try await client.streamChat(model: "qwen2.5:7b", messages: [.user("x")], keepAliveSeconds: 0).first { _ in true }

        let request = try #require(StubProtocol.lastRequest(ns))
        #expect(request.url?.path.hasSuffix("/api/chat") == true)
        let body = try #require(StubProtocol.lastBody(ns))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["keep_alive"] as? Int == 0)
        #expect(json["stream"] as? Bool == true)
        #expect(json["model"] as? String == "qwen2.5:7b")
    }

    @Test func nonSuccessStatusThrowsBeforeReadingStream() async throws {
        let ns = "port-45003"
        StubProtocol.enqueue(ns, "chat", .success((500, Data("boom".utf8))))
        let client = makeClient(port: 45_003)

        do {
            for try await _ in client.streamChat(model: "m", messages: [], keepAliveSeconds: 0) {}
            Issue.record("expected error")
        } catch let error as OllamaError {
            guard case .malformedStream(let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(detail.contains("status 500"))
        }
    }

    @Test func tornLineAfterDeltasIsSkippedNotFatal() async throws {
        let ns = "port-45004"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([
            #"{"message":{"content":"ok"},"done":false}"#,
            #"{"broken json"#,
            #"{"done":true}"#,
        ]))))
        let client = makeClient(port: 45_004)

        var finalText: String?
        var sawError = false
        do {
            for try await delta in client.streamChat(model: "m", messages: [], keepAliveSeconds: 0) {
                if case .final(let text, _) = delta { finalText = text }
            }
        } catch {
            sawError = true
        }
        #expect(!sawError)
        #expect(finalText == "ok")
    }

    @Test func unloadSendsEmptyMessagesWithKeepAliveZero() async throws {
        let ns = "port-45005"
        StubProtocol.enqueue(ns, "chat", .success((200, Data(#"{"done":true}"#.utf8))))
        let client = makeClient(port: 45_005)

        try await client.unload(model: "m")

        let request = try #require(StubProtocol.lastRequest(ns))
        #expect(request.url?.path.hasSuffix("/api/chat") == true)
        let body = try #require(StubProtocol.lastBody(ns))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["keep_alive"] as? Int == 0)
        #expect(json["model"] as? String == "m")
        #expect(json["stream"] as? Bool == false)
        #expect((json["messages"] as? [Any])?.isEmpty == true)
    }
}

/// Streaming publisher behavior over stubbed Telegram API (token-keyed).
@Suite struct StreamingPublisherTests {
    private func makePublisher(token: String) -> (StreamingTelegramPublisher, TelegramClient) {
        let client = TelegramClient(token: token, session: makeStubbedSession())
        let logger = FileLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true), mirrorToStderr: false)
        // Throttle off; typing off so sendChatAction does not race lastBody.
        return (
            StreamingTelegramPublisher(
                client: client,
                logger: logger,
                minEditInterval: 0,
                typingRefreshInterval: nil
            ),
            client
        )
    }

    private static func chatMessageJSON(messageId: Int) -> Data {
        Data(#"{"ok":true,"result":{"message_id":\#(messageId),"date":1,"chat":{"id":555,"type":"private"},"text":"…"}}"#.utf8)
    }

    @Test func placeholderThenEditsThenFinalFullText() async throws {
        let token = "STREAM-HAPPY"
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 10))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 10))))

        let (publisher, _) = makePublisher(token: token)
        let provider = StaticProvider(chunks: [.delta("часть1 "), .delta("часть2"), .final(text: "часть1 часть2", evalCount: nil)])

        let outcome = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)
        guard case .published(let full) = outcome else {
            Issue.record("expected published")
            return
        }
        #expect(full == "часть1 часть2")
        let editBody = try #require(StubProtocol.lastBody(token))
        let lastEdit = try #require(JSONSerialization.jsonObject(with: editBody) as? [String: Any])
        #expect(lastEdit["text"] as? String == "часть1 часть2")
        #expect(lastEdit["message_id"] as? Int == 10)
    }

    @Test func editsAreThrottledToInterval() async throws {
        let token = "STREAM-THROTTLE"
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 11))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 11))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        let logger = FileLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true), mirrorToStderr: false)
        // One hour between edits: no intermediate edit can pass the throttle.
        let publisher = StreamingTelegramPublisher(
            client: client,
            logger: logger,
            minEditInterval: 3600,
            typingRefreshInterval: nil
        )

        let manyDeltas = (1...20).map { ChatDelta.delta(String($0)) }
        let provider = StaticProvider(chunks: manyDeltas + [.final(text: "итог", evalCount: nil)])
        let outcome = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)
        guard case .published = outcome else {
            Issue.record("expected published")
            return
        }
        // Placeholder + exactly one final edit despite 20 rapid deltas.
        #expect(StubProtocol.count(token: token, method: "sendMessage") == 1)
        #expect(StubProtocol.count(token: token, method: "editMessageText") == 1)
    }

    @Test func rateLimitOnEditRetriesOnce() async throws {
        let token = "STREAM-429"
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 12))))
        StubProtocol.enqueue(
            token,
            "editMessageText",
            .success((429, Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":0}}"#.utf8)))
        )
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 12))))

        let (publisher, _) = makePublisher(token: token)
        let provider = StaticProvider(chunks: [.delta("x"), .final(text: "x", evalCount: nil)])

        let outcome = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)
        guard case .published = outcome else {
            Issue.record("expected published")
            return
        }
        // Edits: throttled intermediate (429) + its retry + guaranteed final.
        #expect(StubProtocol.count(token: token, method: "editMessageText") == 3)
        let lastBody = try #require(StubProtocol.lastBody(token))
        let lastJSON = try #require(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
        #expect(lastJSON["text"] as? String == "x")
    }

    @Test func inProgressEditsCarryCursorFinalDoesNot() async throws {
        let token = "STREAM-CURSOR"
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 13))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 13))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 13))))

        let (publisher, _) = makePublisher(token: token)
        let provider = StaticProvider(chunks: [.delta("черновик"), .final(text: "черновик готов", evalCount: nil)])

        let outcome = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)
        guard case .published(let full) = outcome else {
            Issue.record("expected published")
            return
        }
        #expect(full == "черновик готов")
        #expect(!full.contains(StreamingTelegramPublisher.progressCursor))

        let edits = StubProtocol.recordedBodies(token: token, method: "editMessageText")
        #expect(edits.count >= 2)
        let first = try #require(JSONSerialization.jsonObject(with: edits[0]) as? [String: Any])
        let last = try #require(JSONSerialization.jsonObject(with: edits[edits.count - 1]) as? [String: Any])
        #expect(first["text"] as? String == StreamingTelegramPublisher.inProgressText("черновик"))
        #expect(last["text"] as? String == "черновик готов")
    }

    @Test func typingActionFiresWhileStreaming() async throws {
        let token = "STREAM-TYPING"
        StubProtocol.enqueue(token, "sendChatAction", .success((200, Data(#"{"ok":true,"result":true}"#.utf8))))
        StubProtocol.enqueue(token, "sendChatAction", .success((200, Data(#"{"ok":true,"result":true}"#.utf8))))
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 14))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 14))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        let logger = FileLogger(logDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true), mirrorToStderr: false)
        // Long interval: one kick at start, no refresh loop during a short stream.
        let publisher = StreamingTelegramPublisher(
            client: client,
            logger: logger,
            minEditInterval: 0,
            typingRefreshInterval: 60
        )
        let provider = StaticProvider(chunks: [.delta("ok"), .final(text: "ok", evalCount: nil)])
        let outcome = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)
        guard case .published = outcome else {
            Issue.record("expected published")
            return
        }
        #expect(StubProtocol.count(token: token, method: "sendChatAction") >= 1)
        let actionBody = try #require(StubProtocol.recordedBodies(token: token, method: "sendChatAction").first)
        let json = try #require(JSONSerialization.jsonObject(with: actionBody) as? [String: Any])
        #expect(json["action"] as? String == "typing")
        #expect(json["chat_id"] as? Int64 == 555)
    }

    @Test func placeholderIsThinkingMarker() async throws {
        let token = "STREAM-PLACEHOLDER"
        StubProtocol.enqueue(token, "sendMessage", .success((200, Self.chatMessageJSON(messageId: 15))))
        StubProtocol.enqueue(token, "editMessageText", .success((200, Self.chatMessageJSON(messageId: 15))))

        let (publisher, _) = makePublisher(token: token)
        let provider = StaticProvider(chunks: [.final(text: "готово", evalCount: nil)])
        _ = await publisher.stream(chatId: 555, provider: provider, model: "m", messages: [], keepAliveSeconds: 0)

        let sendBody = try #require(StubProtocol.recordedBodies(token: token, method: "sendMessage").first)
        let json = try #require(JSONSerialization.jsonObject(with: sendBody) as? [String: Any])
        #expect(json["text"] as? String == StreamingTelegramPublisher.thinkingPlaceholder)
    }

    /// Minimal in-memory provider standing in for Ollama in publisher tests.
    private struct StaticProvider: ModelProvider {
        let chunks: [ChatDelta]

        func streamChat(model: String, messages: [ChatMessage], tools: [OllamaToolDefinition], keepAliveSeconds: Int) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                }
            }
        }
    }
}

/// Stage-2 config compatibility.
@Suite struct ConfigCompatTests {
    @Test func oldConfigWithoutStageTwoFieldsStillDecodes() throws {
        let old = """
        {"telegram_allowlist":[42],"model":"qwen2.5:7b"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AgentConfig.self, from: old)
        #expect(config.telegramAllowlist == [42])
        #expect(config.idleUnloadMinutes == AgentConfig.default.idleUnloadMinutes)
        #expect(config.ollamaURL == nil)
    }

    @Test func ollamaURLResolutionFallsBackToLocalhost() {
        var config = AgentConfig.default
        #expect(config.resolvedOllamaURL.absoluteString == "http://127.0.0.1:11434")
        config.ollamaURL = "http://192.168.1.10:11434"
        #expect(config.resolvedOllamaURL.host == "192.168.1.10")
    }
}

/// Idle-unloader fires after the configured idle window (accelerated).
@Suite(.serialized) struct IdleUnloaderTests {
    @Test func tickUnloadsAfterIdleWindowOnly() async throws {
        let ns = "port-45006"
        StubProtocol.enqueue(ns, "chat", .success((200, Data(#"{"done":true}"#.utf8))))
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:45006")!, session: makeStubbedSession())
        let loggerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        let logger = FileLogger(logDirectory: loggerDir, mirrorToStderr: false)

        let unloader = IdleUnloader(provider: client, modelName: "m", idleMinutes: 1, logger: logger)

        // Fresh use: must not unload.
        await unloader.noteUsed()
        await unloader.tick(now: Date())
        #expect(StubProtocol.count(token: ns, method: "chat") == 0)

        // After the window passes since last use: unload happens.
        try await Task.sleep(for: .milliseconds(20))
        await unloader.tick(now: Date().addingTimeInterval(120))
        #expect(StubProtocol.count(token: ns, method: "chat") == 1)
    }
}
