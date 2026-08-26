import Foundation
import GRDB
import Testing
@testable import SwiftAgent

@Suite struct DatabaseManagerTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeManager(
        _ dir: URL? = nil,
        quotaOverrideBytes: Int64? = nil,
        provider: (any ModelProvider)? = nil
    ) throws -> (DatabaseManager, URL) {
        let resolvedDir = dir ?? tempDir()
        let url = resolvedDir.appendingPathComponent("agent.sqlite")
        let manager = try DatabaseManager(
            url: url,
            quotaOverrideBytes: quotaOverrideBytes,
            provider: provider
        )
        return (manager, url)
    }

    /// Summarization stub: returns a fixed final chunk, records nothing.
    private struct StubProvider: ModelProvider {
        let summaryText: String

        func streamChat(
            model: String,
            messages: [ChatMessage],
            tools: [OllamaToolDefinition],
            keepAliveSeconds: Int
        ) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.final(text: summaryText, evalCount: 1))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Migrations

    @Test func migrationCreatesAllV1TablesAndIsIdempotent() async throws {
        let (manager, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for table in ["sessions", "messages", "kv", "pending_confirmations", "meta", "messages_fts"] {
            #expect(try await manager.tableExists(table))
        }

        // Second manager over the same file runs the same migrations again.
        _ = try DatabaseManager(url: url)
        let reopened = try DatabaseManager(url: url)
        #expect(try await reopened.tableExists("messages_fts"))
        try await reopened.setValue("1", forKey: "probe")
        #expect(try await reopened.getValue(forKey: "probe") == "1")
    }

    @Test func autoVacuumModePersistsInDatabaseHeader() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // DatabasePool does not create intermediate directories.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.sqlite")

        var config = Configuration()
        config.qos = .utility
        // Reader connections cannot write the header: soft failure, same as prod.
        config.prepareDatabase { db in
            try? db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try Self.databaseMigratorForVerification.migrate(pool)
        let mode = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum")
        }
        // 2 = SQLITE_AUTOVACUUM_INCREMENTAL.
        #expect(mode == 2)
    }

    /// The exact migrator the manager uses, exposed for header verification.
    private static var databaseMigratorForVerification: DatabaseMigrator {
        DatabaseManager.migrator
    }

    // MARK: - Restart persistence

    @Test func historySurvivesRestartOnSameFile() async throws {
        let (first, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await first.appendMessage(sessionId: 42, role: "user", content: "привет из прошлого запуска")
        try await first.appendMessage(sessionId: 42, role: "assistant", content: "ответ")

        let restarted = try DatabaseManager(url: url)
        let messages = try await restarted.recentMessages(chatId: 42, limit: 10)
        #expect(messages.map(\.content) == ["привет из прошлого запуска", "ответ"])
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(try await restarted.messageCount(chatId: 42) == 2)
    }

    @Test func recentMessagesReturnsChronologicalTail() async throws {
        let (manager, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 1...5 {
            try await manager.appendMessage(sessionId: 7, role: "user", content: "msg\(index)")
        }
        let tail = try await manager.recentMessages(chatId: 7, limit: 3)
        #expect(tail.map(\.content) == ["msg3", "msg4", "msg5"])
    }

    // MARK: - FTS5

    @Test func ftsFindsPhraseIncludingCyrillic() async throws {
        let (manager, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await manager.appendMessage(sessionId: 42, role: "user", content: "запомни: пароль от сервера лежит в сейфе")
        try await manager.appendMessage(sessionId: 42, role: "assistant", content: "хорошо, я это учёл")
        try await manager.appendMessage(sessionId: 42, role: "user", content: "totally unrelated english words here")

        let hits = try await manager.search(query: "пароль сервера", limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("сейфе") == true)

        let latin = try await manager.search(query: "english words")
        #expect(latin.count == 1)
    }

    // MARK: - kv

    @Test func kvRoundtripAndPersistenceAcrossManagers() async throws {
        let (first, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await first.setValue("12345", forKey: TelegramListener.offsetKey)
        #expect(try await first.getValue(forKey: TelegramListener.offsetKey) == "12345")

        try await first.setValue("12346", forKey: TelegramListener.offsetKey)
        #expect(try await first.getValue(forKey: TelegramListener.offsetKey) == "12346")

        let second = try DatabaseManager(url: url)
        #expect(try await second.getValue(forKey: TelegramListener.offsetKey) == "12346")

        try await second.setValue(nil, forKey: TelegramListener.offsetKey)
        #expect(try await second.getValue(forKey: TelegramListener.offsetKey) == nil)
    }

    // MARK: - Context assembly

    @Test func buildContextIncludesSystemPromptRecentTurnsAndFtsFragments() async throws {
        let (manager, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Old history: a rare topic phrase that FTS must resurface.
        try await manager.appendMessage(sessionId: 42, role: "user", content: "древнее сообщение про квантовый двигатель")
        try await manager.appendMessage(sessionId: 42, role: "assistant", content: "записал, квантовый двигатель обсудили")

        // Recent turns push the old rows out of the N-message window.
        for index in 1...6 {
            try await manager.appendMessage(sessionId: 42, role: "user", content: "напоминание номер \(index)")
        }

        // New turn resumes the old topic; its terms must pull the history back in.
        try await manager.appendMessage(sessionId: 42, role: "user", content: "вернёмся к квантовому двигателю")

        let context = try await manager.buildContext(
            chatId: 42,
            maxMessages: 4,
            budgetChars: 500,
            systemPrompt: "Ты полезный демон."
        )
        #expect(context.first?.role == "system")
        #expect(context.last?.role == "user")
        let joined = context.map(\.content).joined(separator: "|")
        // FR-14: the rare old topic is re-injected even though it left the window.
        #expect(joined.contains("квантовый"))
        #expect(joined.contains("напоминание номер 6"))
    }

    // MARK: - Quota compression (FR-19)

    @Test func compressionReplacesOldRawMessagesWithSummary() async throws {
        let provider = StubProvider(summaryText: "Суть переписки: готовим квантовый двигатель.")
        // No provider in init: the automatic trigger stays off, so the
        // explicit compressIfNeeded call below owns the whole cycle.
        let (manager, url) = try makeManager(quotaOverrideBytes: 8192)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // One old session with enough raw turns to be compressible (>6).
        for index in 1...10 {
            try await manager.appendMessage(sessionId: 42, role: "user", content: "сырое сообщение \(index) с деталями проекта")
            try await manager.appendMessage(sessionId: 42, role: "assistant", content: "принял \(index)")
        }

        let outcome = await manager.compressIfNeeded(provider: provider, model: "stub")
        guard case .compressed(let sessions, let deleted) = outcome else {
            Issue.record("expected compressed outcome, got \(outcome)")
            return
        }
        #expect(sessions >= 1)
        #expect(deleted >= 1)

        let messages = try await manager.recentMessages(chatId: 42, limit: 100)
        #expect(!messages.isEmpty)
        #expect(messages.count < 20)
        #expect(messages.contains { $0.content.contains("сводка") || $0.content.contains("квантовый") })
        // The newest raw turn is preserved by design.
        #expect(messages.contains { $0.content.contains("принял 10") })

        // Second run may report notNeeded (below threshold) or skipped (busy latch),
        // but must not delete anything further.
        if case .compressed(_, let secondDeleted) = await manager.compressIfNeeded(provider: provider, model: "stub") {
            #expect(secondDeleted == 0, "second run deleted \(secondDeleted) rows unexpectedly")
        }
    }

    @Test func appendMessageTriggersBackgroundCompressionAboveThreshold() async throws {
        let provider = StubProvider(summaryText: "Автосжатие сработало.")
        let (manager, url) = try makeManager(quotaOverrideBytes: 4096, provider: provider)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 1...12 {
            try await manager.appendMessage(
                sessionId: 43,
                role: "user",
                content: "объёмное сообщение \(index), которое раздувает базу сверх порога"
            )
        }

        // The automatic trigger runs asynchronously on QoS .background;
        // poll for the observable end state instead of internals.
        var compressed = false
        for _ in 0..<500 {
            let messages = try await manager.recentMessages(chatId: 43, limit: 100)
            if messages.contains(where: { $0.content.contains("Автосжатие") }) || messages.count <= 8 {
                compressed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(compressed, "background compression did not produce the compressed state in time")

        let messages = try await manager.recentMessages(chatId: 43, limit: 100)
        #expect(messages.contains { $0.content.contains("Автосжатие") } || messages.count <= 8)
    }

    // MARK: - Maintenance

    @Test func maintenanceTickCompletesWithoutError() async throws {
        let (manager, url) = try makeManager()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await manager.appendMessage(sessionId: 9, role: "user", content: "before maintenance")
        await manager.performMaintenance()
        let messages = try await manager.recentMessages(chatId: 9, limit: 10)
        #expect(messages.count == 1)
    }

    // MARK: - FTS query quoting

    @Test func ftsQueryQuotesTermsIndividually() {
        // Terms longer than 5 chars lose the last two (stems); each term is a
        // quoted stem plus prefix star outside the quotes.
        #expect(DatabaseManager.ftsQuery(for: "двигателю") == "\"двигате\" *")
        #expect(DatabaseManager.ftsQuery(for: "кот") == "\"кот\" *")
        #expect(DatabaseManager.ftsQuery(for: "два слова") == "\"два\" * OR \"слова\" *")
        #expect(DatabaseManager.ftsQuery(for: "") == "")
    }
}
