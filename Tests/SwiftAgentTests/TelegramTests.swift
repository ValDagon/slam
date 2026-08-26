import Foundation
import Testing
@testable import SwiftAgent

/// URLProtocol stub: no real network in tests, ever. State is keyed by a
/// namespace derived from the URL — the Telegram bot token for api.telegram.org,
/// the port number for local Ollama — so concurrently running tests never
/// share canned-response queues.
final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Result<(HTTPURLResponse, Data), Error>]] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var methodBodies: [String: [Data]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// Namespace mirror of `namespace(of:)`: Telegram callers pass the raw bot
    /// token, Ollama callers pass "port-<port>".
    private static func key(_ namespace: String, _ method: String) -> String {
        "\(namespace)/\(method)"
    }

    /// Enqueue a canned response for `(namespace, method)`.
    static func enqueue(
        _ namespace: String,
        _ method: String,
        _ result: Result<(Int, Data), Error>,
        headers: [String: String]? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let (status, data)):
            let response = HTTPURLResponse(
                url: URL(string: "https://api.telegram.org")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            queues[key(namespace, method), default: []].append(.success((response, data)))
        case .failure(let error):
            queues[key(namespace, method), default: []].append(.failure(error))
        }
    }

    static func lastRequest(_ token: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[token]
    }

    /// Total number of requests seen for `(token, method)` — used by throttle tests.
    static func count(token: String, method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts["\(token)/\(method)", default: 0]
    }

    static func lastBody(_ token: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bodies[token]
    }

    /// Request bodies for `(token, method)` in arrival order.
    static func recordedBodies(token: String, method: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return methodBodies["\(token)/\(method)", default: []]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let namespace = Self.namespace(of: request)
        let method = request.url?.lastPathComponent ?? ""
        Self.lock.lock()
        defer { Self.lock.unlock() }
        Self.requests[namespace] = request
        Self.counts[Self.key(namespace, method), default: 0] += 1
        if let body = request.httpBody ?? Self.drain(request.httpBodyStream) {
            Self.bodies[namespace] = body
            Self.methodBodies[Self.key(namespace, method), default: []].append(body)
        }
        var queue = Self.queues[Self.key(namespace, method)] ?? []
        let result: Result<(HTTPURLResponse, Data), Error> = queue.isEmpty
            ? .failure(URLError(.unsupportedURL) as Error)
            : queue.removeFirst()
        Self.queues[Self.key(namespace, method)] = queue.isEmpty ? nil : queue

        let client = self.client!
        switch result {
        case .success(let (response, data)):
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Telegram URLs carry the token as /bot<token>/<method>; Ollama is
    /// distinguished by port so parallel tests stay isolated there too.
    private static func namespace(of request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        if url.host == "api.telegram.org", let bot = url.pathComponents.dropFirst().first, bot.hasPrefix("bot") {
            return String(bot.dropFirst(3))
        }
        if let port = url.port { return "port-\(port)" }
        return url.host ?? ""
    }

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

func wrapResult(_ rawJSON: Data) -> Data {
    // Build {"ok":true,"result": <raw>} without re-coding through Codable.
    var out = Data(#"{"ok":true,"result":"#.utf8)
    out.append(rawJSON)
    out.append(Data("}".utf8))
    return out
}

@Suite(.serialized) struct ListenerOffsetTests {
    @Test func listenerPersistsOffsetPlusOneImmediately() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        StubProtocol.enqueue("T", "getUpdates", .success((200, Data("""
        {"ok":true,"result":[{"update_id":500,
          "message": {"message_id": 1, "date": 1756118000,
                      "chat": {"id": 42, "type": "private"},
                      "from": {"id": 42, "is_bot": false},
                      "text": "/start"}}]}
        """.utf8))))
        // The echo reply sendMessage.
        StubProtocol.enqueue("T", "sendMessage", .success((200, Data("""
        {"ok":true,"result":{"message_id":2,"date":1,"chat":{"id":42,"type":"private"},"text":"ok"}}
        """.utf8))))
        // Loop iteration two: empty result.
        StubProtocol.enqueue("T", "getUpdates", .success((200, Data(#"{"ok":true,"result":[]}"#.utf8))))

        let store = FileStateStore(directory: tempDir)
        let config = AgentConfig(telegramAllowlist: [42], model: "m", workingDir: "~", maxContextMessages: 5, idleUnloadMinutes: 5)
        let agent = AgentActor(config: config, configURL: tempDir.appendingPathComponent("cfg.json"), state: store)
        let logger = FileLogger(logDirectory: tempDir.appendingPathComponent("logs"), mirrorToStderr: false)

        let listener = TelegramListener(
            client: TelegramClient(token: "T", session: makeStubbedSession()),
            state: store,
            agent: agent,
            logger: logger,
            backoff: BackoffCalculator(base: 2, maxDelay: 300),
            provider: OllamaClient(),
            publisher: StreamingTelegramPublisher(
                client: TelegramClient(token: "T", session: makeStubbedSession()),
                logger: logger,
                typingRefreshInterval: nil
            )
        )

        let task = Task(priority: .utility) { await listener.run() }
        // Wait until offset from update 500 is persisted.
        for _ in 0..<100 where store.get(TelegramListener.offsetKey) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()

        #expect(store.get(TelegramListener.offsetKey) == "501")
    }
}

@Suite(.serialized) struct AgentActorTests {
    private func makeAgent(allowlist: [Int64], maxContextMessages: Int = 5) -> (AgentActor, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        let config = AgentConfig(
            telegramAllowlist: allowlist,
            model: "qwen2.5:7b",
            workingDir: "~",
            maxContextMessages: maxContextMessages,
            idleUnloadMinutes: 5
        )
        let url = dir.appendingPathComponent("config.json")
        do {
            let database = try DatabaseManager(
                url: dir.appendingPathComponent("agent.sqlite"),
                quotaOverrideBytes: nil
            )
            return (AgentActor(config: config, configURL: url, state: FileStateStore(directory: dir), database: database), url)
        } catch {
            Issue.record("database setup failed: \(error)")
            return (AgentActor(config: config, configURL: url, state: FileStateStore(directory: dir)), url)
        }
    }

    private func update(text: String, sender: Int64 = 42) -> TgUpdate {
        TgUpdate(
            updateId: Int.random(in: 1...100000),
            message: TgMessage(
                messageId: 1,
                from: TgUser(id: sender, isBot: false, firstName: "V", username: nil),
                chat: TgChat(id: sender, type: "private"),
                date: 1756118000,
                text: text
            ),
            callbackQuery: nil
        )
    }

    @Test func allowlistGateBlocksStrangers() async {
        let (agent, _) = makeAgent(allowlist: [42])
        #expect(await agent.route(update(text: "hi", sender: 777)) == .ignore)
        guard case .deliver(let owner) = await agent.route(update(text: "hi", sender: 42)) else {
            Issue.record("expected deliver")
            return
        }
        #expect(owner.senderId == 42)
        #expect(await agent.route(update(text: "", sender: 42)) == .ignore)
    }

    @Test func strangerStartOffersPairing() async {
        let (agent, _) = makeAgent(allowlist: [42])
        #expect(await agent.route(update(text: "/start", sender: 777)) == .pairing(chatId: 777, senderId: 777))
        #expect(await agent.route(update(text: "привет", sender: 777)) == .ignore)
    }

    @Test func plainTextBecomesModelStreamPlan() async throws {
        let (agent, _) = makeAgent(allowlist: [42])
        guard case .deliver(let routed) = await agent.route(update(text: "как дела?")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .modelStream(let userText, let context) = await agent.planReply(for: routed) else {
            Issue.record("expected modelStream plan")
            return
        }
        #expect(userText == "как дела?")
        #expect(context.last?.content == "как дела?")
    }

    @Test func contextKeepsLastNMessagesAndAssistantTurns() async throws {
        let (agent, _) = makeAgent(allowlist: [42], maxContextMessages: 3)
        for i in 1...4 {
            guard case .deliver(let routed) = await agent.route(update(text: "msg\(i)")) else {
                Issue.record("expected deliver")
                return
            }
            guard case .modelStream = await agent.planReply(for: routed) else {
                Issue.record("expected stream plan")
                return
            }
            await agent.noteAssistantReply(chatId: 42, text: "ans\(i)")
        }
        guard case .deliver(let routed) = await agent.route(update(text: "final")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .modelStream(_, let context) = await agent.planReply(for: routed) else {
            Issue.record("expected stream plan")
            return
        }
        // Cap keeps the last three turns: user msg4, its answer, the new turn.
        #expect(context.map(\.content) == ["msg4", "ans4", "final"])
    }

    @Test func commandsResolveToPlainPlans() async throws {
        let (agent, url) = makeAgent(allowlist: [42])

        guard case .deliver(let allowRoute) = await agent.route(update(text: "/allow 777")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .plain(let reply) = await agent.planReply(for: allowRoute) else {
            Issue.record("expected plain plan")
            return
        }
        #expect(reply == "777 добавлен в allowlist.")
        let persisted = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: url))
        #expect(persisted.telegramAllowlist.contains(777))

        guard case .deliver(let denyRoute) = await agent.route(update(text: "/deny 777")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .plain(let denyReply) = await agent.planReply(for: denyRoute) else {
            Issue.record("expected plain plan")
            return
        }
        #expect(denyReply == "777 удалён из allowlist.")

        guard case .deliver(let denySelfRoute) = await agent.route(update(text: "/deny 42")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .plain(let denySelf) = await agent.planReply(for: denySelfRoute) else {
            Issue.record("expected plain plan")
            return
        }
        #expect(denySelf.contains("Нельзя удалить владельца"))

        guard case .deliver(let modelRoute) = await agent.route(update(text: "/model llama3:8b")) else {
            Issue.record("expected deliver")
            return
        }
        guard case .plain(let modelReply) = await agent.planReply(for: modelRoute) else {
            Issue.record("expected plain plan")
            return
        }
        #expect(modelReply.contains("llama3:8b"))
        let afterModel = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: url))
        #expect(afterModel.model == "llama3:8b")

        // Stranger cannot manage access; their updates are dropped by the gate.
        #expect(await agent.route(update(text: "/allow 999", sender: 777)) == .ignore)
    }

    @Test func statusContainsCountersAndUptime() async {
        let (agent, _) = makeAgent(allowlist: [42])
        _ = await agent.route(update(text: "/start"))
        await agent.noteConflict()
        let status = await agent.statusText()
        #expect(status.contains("updates received: 1"))
        #expect(status.contains("conflicts 409: 1"))
        #expect(status.contains("mode: ollama stream"))
    }

    /// Regression for a live-test bug (2026-08-26): `echo x > file.txt` denied
    /// by the sandbox's write-scope rule (WORKING_DIR/tmp only) was rendered
    /// with the read-scope hint text ("reads only within workspace"), which
    /// contradicted what actually happened — the read of workspace succeeded,
    /// only the write outside tmp/ was denied.
    @Test func deniedWriteOutsideTmpGetsWriteScopeHint() {
        let result = ProcessResult(
            outcome: .completed,
            exitCode: 1,
            exitSignal: nil,
            stdout: "",
            stderr: "zsh:1: operation not permitted: test.txt",
            sandboxVerdict: .ran,
            truncated: false
        )
        let rendered = AgentActor.render(
            result: result,
            command: #"echo "test" > test.txt"#,
            workingDir: "/Users/demo/.local/share/slam/workspace",
            sandboxEnabled: true
        )
        #expect(rendered.contains("запись только в"))
        #expect(rendered.contains("/tmp"))
        #expect(!rendered.contains("чтение только в workspace"))
    }

    @Test func deniedReadOutsideWorkspaceGetsReadScopeHint() {
        let result = ProcessResult(
            outcome: .completed,
            exitCode: 1,
            exitSignal: nil,
            stdout: "",
            stderr: "cat: /Users/demo/Documents/x.txt: Operation not permitted",
            sandboxVerdict: .ran,
            truncated: false
        )
        let rendered = AgentActor.render(
            result: result,
            command: "cat /Users/demo/Documents/x.txt",
            workingDir: "/Users/demo/.local/share/slam/workspace",
            sandboxEnabled: true
        )
        #expect(rendered.contains("чтение только в workspace"))
    }
}
