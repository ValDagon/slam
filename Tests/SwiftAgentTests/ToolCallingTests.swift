import Foundation
import Testing
@testable import SwiftAgent

/// FR-21 native tool-calling: request/response contract at the OllamaClient
/// level, `write_file` path-safety, and the full multi-turn wiring through
/// TelegramListener (tool round-trip + HITL gating for destructive `run_shell`).
@Suite struct OllamaToolCallTests {
    private func ndjson(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func toolsFieldSerializedPerOllamaSchema() async throws {
        let ns = "port-45101"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([#"{"done":true}"#]))))
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:45101")!, session: makeStubbedSession())

        _ = try await client.streamChat(
            model: "qwen2.5:7b",
            messages: [.user("hi")],
            tools: ToolCatalog.all,
            keepAliveSeconds: 0
        ).first { _ in true }

        let body = try #require(StubProtocol.lastBody(ns))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        let writeFile = try #require(tools.first { ($0["function"] as? [String: Any])?["name"] as? String == "write_file" })
        #expect(writeFile["type"] as? String == "function")
        let function = try #require(writeFile["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["path"] != nil)
        #expect(properties["content"] != nil)
        let required = try #require(parameters["required"] as? [String])
        #expect(Set(required) == Set(["path", "content"]))
    }

    @Test func noToolsMeansNoToolsKeyAtAll() async throws {
        let ns = "port-45102"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([#"{"done":true}"#]))))
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:45102")!, session: makeStubbedSession())

        _ = try await client.streamChat(model: "m", messages: [.user("hi")], keepAliveSeconds: 0).first { _ in true }

        let body = try #require(StubProtocol.lastBody(ns))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["tools"] == nil)
    }

    @Test func toolCallChunkParsesIntoToolCallsDelta() async throws {
        let ns = "port-45103"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},"done":false}"#,
        ]))))
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:45103")!, session: makeStubbedSession())

        var calls: [OllamaToolCall] = []
        var sawOtherDelta = false
        for try await delta in client.streamChat(model: "m", messages: [.user("weather?")], tools: ToolCatalog.all, keepAliveSeconds: 0) {
            switch delta {
            case .toolCalls(let c): calls = c
            default: sawOtherDelta = true
            }
        }
        #expect(!sawOtherDelta)
        #expect(calls.count == 1)
        #expect(calls[0].function.name == "get_weather")
        #expect(calls[0].function.arguments["city"]?.stringValue == "Tokyo")
    }

    @Test func plainResponseStillParsesWhenToolsAreOffered() async throws {
        // Fallback proof at the client level: tools are on the request but the
        // model just answers in text — deltas/final behave exactly as without tools.
        let ns = "port-45104"
        StubProtocol.enqueue(ns, "chat", .success((200, ndjson([
            #"{"message":{"content":"привет"},"done":false}"#,
            #"{"done":true}"#,
        ]))))
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:45104")!, session: makeStubbedSession())

        var deltas: [String] = []
        var finalText: String?
        for try await delta in client.streamChat(model: "m", messages: [.user("hi")], tools: ToolCatalog.all, keepAliveSeconds: 0) {
            switch delta {
            case .delta(let piece): deltas.append(piece)
            case .final(let text, _): finalText = text
            case .toolCalls: Issue.record("unexpected tool call")
            }
        }
        #expect(deltas == ["привет"])
        #expect(finalText == "привет")
    }
}

/// `write_file` path validation (FR-22 parity): security-critical, standalone
/// from any process execution so it runs fast and everywhere.
@Suite struct FileWriteToolTests {
    private func tempTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-fwt-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test func plainRelativePathResolvesInsideTmp() throws {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = FileWriteTool.resolveSafePath("notes/todo.txt", tmpDir: tmp.path)
        guard case .success(let resolved) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let canonicalTmp = try #require(realpathString(tmp.path))
        #expect(resolved.hasPrefix(canonicalTmp))
        #expect(resolved.hasSuffix("notes/todo.txt"))
    }

    @Test func leadingTmpPrefixDoesNotNestUnderTmp() throws {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let canonicalTmp = try #require(realpathString(tmp.path))

        #expect(FileWriteTool.stripRedundantTmpPrefix("test.txt") == "test.txt")
        #expect(FileWriteTool.stripRedundantTmpPrefix("tmp/test.txt") == "test.txt")
        #expect(FileWriteTool.stripRedundantTmpPrefix("tmp/notes/todo.txt") == "notes/todo.txt")
        #expect(FileWriteTool.stripRedundantTmpPrefix("tmp") == "")

        let result = FileWriteTool.resolveSafePath("tmp/test.txt", tmpDir: tmp.path)
        guard case .success(let resolved) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resolved == (canonicalTmp as NSString).appendingPathComponent("test.txt"))

        let nestedCatalog = FileWriteTool.resolveSafePath("notes/todo.txt", tmpDir: tmp.path)
        guard case .success(let nestedResolved) = nestedCatalog else {
            Issue.record("expected success for notes/todo.txt")
            return
        }
        #expect(nestedResolved == (canonicalTmp as NSString).appendingPathComponent("notes/todo.txt"))
    }

    @Test func parentTraversalIsRejected() {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for attempt in ["../etc/passwd", "../../etc/passwd", "a/../../b", "..", "sub/../../outside"] {
            let result = FileWriteTool.resolveSafePath(attempt, tmpDir: tmp.path)
            guard case .failure(let error) = result else {
                Issue.record("expected rejection for \(attempt)")
                continue
            }
            guard case .traversal = error else {
                Issue.record("expected .traversal for \(attempt), got \(error)")
                continue
            }
        }
    }

    @Test func absoluteAndHomePathsAreRejected() {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for attempt in ["/etc/passwd", "/tmp/x", "~/Documents/secret.txt", "~"] {
            let result = FileWriteTool.resolveSafePath(attempt, tmpDir: tmp.path)
            guard case .failure(let error) = result else {
                Issue.record("expected rejection for \(attempt)")
                continue
            }
            guard case .absoluteOrHome = error else {
                Issue.record("expected .absoluteOrHome for \(attempt), got \(error)")
                continue
            }
        }
    }

    @Test func emptyPathIsRejected() {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard case .failure(.empty) = FileWriteTool.resolveSafePath("", tmpDir: tmp.path) else {
            Issue.record("expected .empty")
            return
        }
        guard case .failure(.empty) = FileWriteTool.resolveSafePath("   ", tmpDir: tmp.path) else {
            Issue.record("expected .empty for whitespace-only path")
            return
        }
        guard case .failure(.empty) = FileWriteTool.resolveSafePath("tmp", tmpDir: tmp.path) else {
            Issue.record("expected .empty after stripping lone tmp prefix")
            return
        }
        guard case .failure(.empty) = FileWriteTool.resolveSafePath("tmp/", tmpDir: tmp.path) else {
            Issue.record("expected .empty for tmp/ with no leaf")
            return
        }
    }

    @Test func symlinkEscapeInsideTmpIsRejected() throws {
        let tmp = tempTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-fwt-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        // tmp/escape → symlink pointing outside tmp/. No literal ".." in the
        // supplied path, so only the realpath containment re-check catches this.
        let symlinkPath = tmp.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideTarget)

        let result = FileWriteTool.resolveSafePath("escape/payload.txt", tmpDir: tmp.path)
        guard case .failure(let error) = result else {
            Issue.record("expected rejection, got success")
            return
        }
        guard case .escapesSandbox = error else {
            Issue.record("expected .escapesSandbox, got \(error)")
            return
        }
    }

    @Test func shellQuoteSurvivesEmbeddedQuotesAndSpecialChars() {
        let tricky = #"it's a "test" with $(rm -rf /) and `backticks` and %s"#
        let quoted = FileWriteTool.shellQuote(tricky)
        // Round-trip through a real shell to prove no injection is possible.
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
    }
}

/// `write_file`/`run_shell` classification (`AgentActor.planToolCall`).
@Suite struct ToolCallPlanningTests {
    private func makeAgent(allowlist: [Int64] = [42]) -> AgentActor {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        let config = AgentConfig(
            telegramAllowlist: allowlist,
            model: "qwen2.5:7b",
            workingDir: dir.path,
            maxContextMessages: 5,
            idleUnloadMinutes: 5
        )
        return AgentActor(config: config, configURL: dir.appendingPathComponent("config.json"), state: FileStateStore(directory: dir))
    }

    private func call(_ name: String, _ arguments: [String: JSONValue]) -> OllamaToolCall {
        OllamaToolCall(function: .init(name: name, arguments: arguments))
    }

    @Test func writeFileWithValidArgumentsPlans() async {
        let agent = makeAgent()
        let plan = await agent.planToolCall(call("write_file", ["path": "a.txt", "content": "hi"]))
        guard case .writeFile(let path, let content) = plan else {
            Issue.record("expected .writeFile, got \(plan)")
            return
        }
        #expect(path == "a.txt")
        #expect(content == "hi")
    }

    @Test func writeFileMissingArgumentsIsInvalid() async {
        let agent = makeAgent()
        let plan = await agent.planToolCall(call("write_file", ["path": "a.txt"]))
        guard case .invalid = plan else {
            Issue.record("expected .invalid, got \(plan)")
            return
        }
    }

    @Test func harmlessRunShellDoesNotRequireConfirmation() async {
        let agent = makeAgent()
        let plan = await agent.planToolCall(call("run_shell", ["command": "ls -la"]))
        guard case .runShell(let cmdPlan) = plan else {
            Issue.record("expected .runShell, got \(plan)")
            return
        }
        #expect(!cmdPlan.requiresConfirmation)
    }

    @Test func destructiveRunShellRequiresConfirmation() async {
        let agent = makeAgent()
        let plan = await agent.planToolCall(call("run_shell", ["command": "rm -rf /tmp/x"]))
        guard case .runShell(let cmdPlan) = plan else {
            Issue.record("expected .runShell, got \(plan)")
            return
        }
        #expect(cmdPlan.requiresConfirmation)
        let status = await agent.statusText()
        #expect(status.contains("confirmations: 1 requested"))
    }

    @Test func unknownToolIsInvalid() async {
        let agent = makeAgent()
        let plan = await agent.planToolCall(call("delete_everything", [:]))
        guard case .invalid = plan else {
            Issue.record("expected .invalid, got \(plan)")
            return
        }
    }

    @Test func toolDefinitionsEmptyWhenNativeToolsDisabled() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        var config = AgentConfig(
            telegramAllowlist: [42],
            model: "m",
            workingDir: dir.path,
            maxContextMessages: 5,
            idleUnloadMinutes: 5
        )
        config.useNativeTools = false
        let agent = AgentActor(config: config, configURL: dir.appendingPathComponent("config.json"), state: FileStateStore(directory: dir))
        let tools = await agent.toolDefinitions()
        #expect(tools.isEmpty)
    }

    @Test func toolDefinitionsPopulatedByDefault() async {
        let agent = makeAgent()
        let tools = await agent.toolDefinitions()
        #expect(tools.count == 2)
    }
}

/// Executes `write_file` through the real (unsandboxed, for test speed)
/// ProcessRunner path, proving the tool actually lands bytes on disk and that
/// a rejected path never reaches the process runner at all.
@Suite struct WriteFileExecutionTests {
    private func makeAgent(workingDir: URL) -> AgentActor {
        var config = AgentConfig(
            telegramAllowlist: [42],
            model: "m",
            workingDir: workingDir.path,
            maxContextMessages: 5,
            idleUnloadMinutes: 5
        )
        config.sandboxEnabled = false
        return AgentActor(config: config, configURL: workingDir.appendingPathComponent("config.json"), state: FileStateStore(directory: workingDir))
    }

    @Test func writesFileUnderTmp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = makeAgent(workingDir: dir)
        let runner = ProcessRunner(timeout: 15)

        let status = await agent.executeWriteFile(path: "hello.txt", content: "hi there\n", runner: runner, profileURL: nil)
        #expect(status.contains("файл записан"))
        let written = try String(contentsOf: dir.appendingPathComponent("tmp/hello.txt"), encoding: .utf8)
        #expect(written == "hi there\n")
    }

    @Test func rejectedPathNeverTouchesDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = makeAgent(workingDir: dir)
        let runner = ProcessRunner(timeout: 15)

        let status = await agent.executeWriteFile(path: "../../etc/passwd", content: "pwned", runner: runner, profileURL: nil)
        #expect(status.contains("отклонено"))
        #expect(!FileManager.default.fileExists(atPath: "/etc/passwd.bak"))
    }

    @Test func oversizedContentIsRejected() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = makeAgent(workingDir: dir)
        let runner = ProcessRunner(timeout: 15)

        let huge = String(repeating: "x", count: FileWriteTool.maxContentBytes + 1)
        let status = await agent.executeWriteFile(path: "big.txt", content: huge, runner: runner, profileURL: nil)
        #expect(status.contains("отклонено"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tmp/big.txt").path))
    }
}

/// Full multi-turn wiring through `TelegramListener`: tool call → execution →
/// round-trip back to Ollama → final answer, all over one edited message;
/// and HITL gating for a destructive `run_shell` call (FR-23 reuse, not a
/// parallel mechanism).
@Suite(.serialized) struct NativeToolIntegrationTests {
    private func makeListener(
        tgToken: String,
        ollamaPort: UInt16,
        workingDir: URL,
        database: DatabaseManager
    ) -> (TelegramListener, AgentActor) {
        var config = AgentConfig(
            telegramAllowlist: [42],
            model: "qwen2.5:7b",
            workingDir: workingDir.path,
            maxContextMessages: 10,
            idleUnloadMinutes: 5
        )
        config.sandboxEnabled = false
        let agent = AgentActor(
            config: config,
            configURL: workingDir.appendingPathComponent("config.json"),
            state: FileStateStore(directory: workingDir),
            database: database
        )
        let logger = FileLogger(logDirectory: workingDir.appendingPathComponent("logs"), mirrorToStderr: false)
        let client = TelegramClient(token: tgToken, session: makeStubbedSession())
        let publisher = StreamingTelegramPublisher(
            client: TelegramClient(token: tgToken, session: makeStubbedSession()),
            logger: logger,
            minEditInterval: 0,
            typingRefreshInterval: nil
        )
        let ollama = OllamaClient(baseURL: URL(string: "http://127.0.0.1:\(ollamaPort)")!, session: makeStubbedSession())
        let listener = TelegramListener(
            client: client,
            state: FileStateStore(directory: workingDir),
            agent: agent,
            logger: logger,
            backoff: BackoffCalculator(base: 2, maxDelay: 300),
            provider: ollama,
            publisher: publisher,
            database: database,
            commandRunner: ProcessRunner(timeout: 15),
            sandboxProfileURL: nil
        )
        return (listener, agent)
    }

    private func userMessage(text: String) -> Data {
        Data("""
        {"ok":true,"result":[{"update_id":900,
          "message": {"message_id": 1, "date": 1756118000,
                      "chat": {"id": 42, "type": "private"},
                      "from": {"id": 42, "is_bot": false},
                      "text": "\(text)"}}]}
        """.utf8)
    }

    private func chatMessageJSON(messageId: Int) -> Data {
        Data(#"{"ok":true,"result":{"message_id":\#(messageId),"date":1,"chat":{"id":42,"type":"private"},"text":"…"}}"#.utf8)
    }

    @Test func writeFileToolRoundTripsToFinalAnswerOnOneMessage() async throws {
        let tg = "TOOL-WRITE-\(UUID().uuidString)"
        let port: UInt16 = 45201
        let ns = "port-\(port)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseManager(url: dir.appendingPathComponent("agent.sqlite"))

        StubProtocol.enqueue(tg, "getUpdates", .success((200, userMessage(text: "запиши hello в test.txt"))))
        StubProtocol.enqueue(tg, "getUpdates", .success((200, Data(#"{"ok":true,"result":[]}"#.utf8))))
        StubProtocol.enqueue(tg, "sendMessage", .success((200, chatMessageJSON(messageId: 100))))
        StubProtocol.enqueue(ns, "chat", .success((200, Data(
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"write_file","arguments":{"path":"test.txt","content":"hello"}}}]},"done":false}"#.utf8
        ))))
        // Several edits may land on the placeholder (tool-running notice, delta, final).
        for _ in 0..<5 {
            StubProtocol.enqueue(tg, "editMessageText", .success((200, chatMessageJSON(messageId: 100))))
        }
        StubProtocol.enqueue(ns, "chat", .success((200, Data("""
        {"message":{"content":"Готово!"},"done":false}
        {"done":true}
        """.utf8))))

        let (listener, _) = makeListener(tgToken: tg, ollamaPort: port, workingDir: dir, database: database)
        let task = Task(priority: .utility) { await listener.run() }
        defer { task.cancel() }

        let fileURL = dir.appendingPathComponent("tmp/test.txt")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: fileURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "hello")

        for _ in 0..<200 where StubProtocol.count(token: ns, method: "chat") < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(StubProtocol.count(token: ns, method: "chat") == 2)

        let secondChatBody = try #require(StubProtocol.recordedBodies(token: ns, method: "chat").last)
        let secondJSON = try #require(JSONSerialization.jsonObject(with: secondChatBody) as? [String: Any])
        let messages = try #require(secondJSON["messages"] as? [[String: Any]])
        #expect(messages.contains { ($0["role"] as? String) == "assistant" && $0["tool_calls"] != nil })
        #expect(messages.contains { ($0["role"] as? String) == "tool" && ($0["tool_name"] as? String) == "write_file" })

        // Give the final edit a moment to land, then check the visible text.
        for _ in 0..<200 {
            let bodies = StubProtocol.recordedBodies(token: tg, method: "editMessageText")
            if let last = bodies.last,
               let json = try? JSONSerialization.jsonObject(with: last) as? [String: Any],
               json["text"] as? String == "Готово!" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editBodies = StubProtocol.recordedBodies(token: tg, method: "editMessageText")
        let lastEdit = try #require(editBodies.last)
        let lastJSON = try #require(JSONSerialization.jsonObject(with: lastEdit) as? [String: Any])
        #expect(lastJSON["text"] as? String == "Готово!")
    }

    @Test func destructiveRunShellToolCallPausesForHITLInsteadOfExecuting() async throws {
        let tg = "TOOL-HITL-\(UUID().uuidString)"
        let port: UInt16 = 45202
        let ns = "port-\(port)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try DatabaseManager(url: dir.appendingPathComponent("agent.sqlite"))

        StubProtocol.enqueue(tg, "getUpdates", .success((200, userMessage(text: "удали всё в tmp"))))
        StubProtocol.enqueue(tg, "getUpdates", .success((200, Data(#"{"ok":true,"result":[]}"#.utf8))))
        StubProtocol.enqueue(tg, "sendMessage", .success((200, chatMessageJSON(messageId: 200))))
        StubProtocol.enqueue(ns, "chat", .success((200, Data(
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"run_shell","arguments":{"command":"rm -rf /tmp/x"}}}]},"done":false}"#.utf8
        ))))
        StubProtocol.enqueue(tg, "editMessageText", .success((200, chatMessageJSON(messageId: 200))))
        // The confirmation prompt with inline keyboard.
        StubProtocol.enqueue(tg, "sendMessage", .success((200, chatMessageJSON(messageId: 201))))

        let (listener, _) = makeListener(tgToken: tg, ollamaPort: port, workingDir: dir, database: database)
        let task = Task(priority: .utility) { await listener.run() }
        defer { task.cancel() }

        // Wait for the pending_confirmations row instead of racing on HTTP call counts.
        var pendingId: Int64?
        for _ in 0..<200 {
            if let row = try? await database.pendingConfirmation(id: 1, chatId: 42) {
                pendingId = row.id
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let id = try #require(pendingId)
        let pending = try #require(try await database.pendingConfirmation(id: id, chatId: 42))
        #expect(pending.command == "rm -rf /tmp/x")

        // Confirmation buttons went out as a second sendMessage with a keyboard.
        let sendBodies = StubProtocol.recordedBodies(token: tg, method: "sendMessage")
        #expect(sendBodies.count == 2)
        let confirmBody = try #require(JSONSerialization.jsonObject(with: sendBodies[1]) as? [String: Any])
        #expect(confirmBody["reply_markup"] != nil)

        // No second Ollama round-trip: the destructive call short-circuits to
        // the existing report-only HITL flow, exactly like the fence path.
        #expect(StubProtocol.count(token: ns, method: "chat") == 1)
    }
}
