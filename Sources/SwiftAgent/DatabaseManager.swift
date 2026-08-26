import Foundation
import GRDB

/// Disk quota for the storage directory (FR-19): min(10% free space, 20 GiB),
/// overridable for tests and power users.
struct StorageQuota: Sendable {
    let bytes: Int64

    static let hardCap: Int64 = 20 * 1024 * 1024 * 1024
    /// Compression starts when usage reaches this share of the quota.
    static let compressionThresholdShare = 0.85

    init(databaseFileURL: URL, overrideBytes: Int64?) {
        if let overrideBytes {
            self.bytes = max(1, overrideBytes)
            return
        }
        let dir = databaseFileURL.deletingLastPathComponent()
        let free = (try? dir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage ?? 0
        self.bytes = max(1024, min(Int64(free) / 10, Self.hardCap))
    }
}

/// SQLite persistence layer (stage 3): sessions/messages with FTS5,
/// kv store, HITL placeholders, disk quota and maintenance.
///
/// One DatabasePool per process (WAL mode); all access goes through the
/// actor, so no shared mutable state escapes it. Queries stay raw SQL on
/// purpose: no record generics, no schema-cache surprises.
actor DatabaseManager {
    private let pool: DatabasePool
    private let dbURL: URL
    private let quotaBytes: Int64
    private let logger: FileLogger?
    private let provider: (any ModelProvider)?
    private let modelName: String
    /// Scheduling latch for the automatic post-write quota check.
    private var compressionInFlight = false
    /// Execution mutex shared by every compression entry point.
    private var compacting = false
    private(set) var lastCompressionAt: Date?

    // MARK: - Lifecycle

    nonisolated static let databaseConfiguration: Configuration = {
        var config = Configuration()
        config.qos = .utility
        // Must land while the database is empty to take effect. Reader-only
        // pool connections cannot write the header, hence the soft failure:
        // the writer applies it at creation time.
        config.prepareDatabase { db in
            try? db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        return config
    }()

    init(
        url: URL? = nil,
        quotaOverrideBytes: Int64? = nil,
        provider: (any ModelProvider)? = nil,
        modelName: String = "",
        logger: FileLogger? = nil
    ) throws {
        let resolvedURL = url ?? Paths.databaseURL()
        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: resolvedURL.path, configuration: Self.databaseConfiguration)

        try Self.migrator.migrate(pool)
        self.pool = pool
        self.dbURL = resolvedURL
        self.quotaBytes = StorageQuota(databaseFileURL: resolvedURL, overrideBytes: quotaOverrideBytes).bytes
        self.provider = provider
        self.modelName = modelName
        self.logger = logger
    }

    var quotaLimitBytes: Int64 { quotaBytes }

    var databaseFileSizeBytes: Int64 {
        get async throws {
            try await pool.read { [dbURL] _ in
                // WAL mode: the payload lives in -wal until checkpoint,
                // so quota accounting must include sidecar files too.
                Self.diskUsage(of: dbURL)
            }
        }
    }

    nonisolated private static func diskUsage(of url: URL) -> Int64 {
        var total: Int64 = 0
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                if let size = attrs[.size] as? Int64 {
                    total += size
                } else if let size = attrs[.size] as? Int {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    // MARK: - Migrations (v1)

    nonisolated static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Note: auto_vacuum is NOT set here — pragmas inside the
            // migration transaction are ineffective. It is applied at
            // connection setup while the database file is still empty.

            try db.create(table: "sessions") { t in
                // Explicit PK: messages.session_id references the table
                // without a column list, so SQLite needs a real primary key.
                t.column("chat_id", .integer).primaryKey()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .integer)
                    .notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            // Stage-4 placeholder: created now per FR-18, used by HITL later.
            try db.create(table: "pending_confirmations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chat_id", .integer).notNull()
                t.column("command", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("expires_at", .datetime).notNull()
            }

            try db.execute(
                sql: "ALTER TABLE pending_confirmations ADD COLUMN message_id INTEGER"
            )

            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            // External-content FTS5 over messages; synchronize() derives
            // content=/content_rowid= from the primary key and installs
            // sync triggers + initial rebuild. unicode61 covers Cyrillic.
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.tokenizer = .unicode61()
                t.column("content")
            }
        }

        return migrator
    }()

    // MARK: - Sessions & messages

    /// Appends a message, creating/keeping the session row; returns its row id.
    @discardableResult
    func appendMessage(sessionId chatId: Int64, role: String, content: String) async throws -> Int64 {
        let insertedId: Int64 = try await pool.write { db in
            try Self.ensureSession(db, chatId: chatId)
            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                arguments: [chatId, role, content, Date()]
            )
            return db.lastInsertedRowID
        }
        await enforceQuotaIfNeeded()
        return insertedId
    }

    /// Last `limit` messages of a session in chronological order.
    func recentMessages(chatId: Int64, limit: Int) async throws -> [ChatMessage] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT role, content FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?",
                arguments: [chatId, limit]
            )
            return rows.reversed().map(Self.chatMessage(from:))
        }
    }

    func messageCount(chatId: Int64) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                arguments: [chatId]
            ) ?? 0
        }
    }

    nonisolated private static func chatMessage(from row: Row) -> ChatMessage {
        let role: String = row["role"] ?? "user"
        let content: String = row["content"] ?? ""
        return ChatMessage(role: role, content: content)
    }

    private static func ensureSession(_ db: Database, chatId: Int64) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions (chat_id, created_at) VALUES (?, ?)
            ON CONFLICT(chat_id) DO NOTHING
            """,
            arguments: [chatId, Date()]
        )
    }

    // MARK: - FTS5

    struct SearchHit: Sendable, Equatable {
        let content: String
        let snippet: String
    }

    func search(query: String, limit: Int = 5) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.content AS content,
                       snippet(messages_fts, 0, '', '', '…', 12) AS snip
                FROM messages_fts fts
                JOIN messages m ON m.id = fts.rowid
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                arguments: [Self.ftsQuery(for: trimmed), limit]
            )
            var out: [SearchHit] = []
            for row in rows {
                let content: String = row["content"] ?? ""
                let snip: String = row["snip"] ?? ""
                out.append(SearchHit(content: content, snippet: snip))
            }
            return out
        }
    }

    /// Quote each term; prefix matching over truncated stems absorbs Russian
    /// morphology (двигателю → двигатель*) where unicode61 has no stemmer.
    /// OR semantics + bm25 ranking surface rare terms above noisy ones.
    static func ftsQuery(for raw: String) -> String {
        raw.split(separator: " ")
            .map { word -> String in
                var stem = String(word)
                if stem.count > 5 {
                    stem = String(stem.dropLast(2))
                }
                return "\"\(stem)\" *"
            }
            .joined(separator: " OR ")
    }

    // MARK: - Pending confirmations (stage 4, FR-23)

    struct PendingConfirmation: Sendable, Equatable {
        let id: Int64
        let chatId: Int64
        let messageId: Int?
        let command: String
        let createdAt: Date
        let expiresAt: Date
    }

    enum ConfirmationError: Error {
        case notFound
    }

    @discardableResult
    func insertPendingConfirmation(
        chatId: Int64,
        messageId: Int?,
        command: String,
        ttl: TimeInterval
    ) async throws -> Int64 {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO pending_confirmations (chat_id, message_id, command, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [chatId, messageId, command, Date(), Date().addingTimeInterval(ttl)]
            )
            return db.lastInsertedRowID
        }
    }

    /// Returns the row only when unexpired and belonging to the given chat.
    func pendingConfirmation(id: Int64, chatId: Int64) async throws -> PendingConfirmation? {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, chat_id, message_id, command, created_at, expires_at FROM pending_confirmations WHERE id = ? AND chat_id = ?",
                arguments: [id, chatId]
            )
            guard let row = rows.first else { return nil }
            let expires: Date = row["expires_at"]
            guard expires > Date() else { return nil }
            return PendingConfirmation(
                id: row["id"],
                chatId: row["chat_id"],
                messageId: row["message_id"],
                command: row["command"],
                createdAt: row["created_at"],
                expiresAt: expires
            )
        }
    }

    @discardableResult
    func deletePendingConfirmation(id: Int64) async throws -> Bool {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM pending_confirmations WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Maintenance hook: expired HITL requests are garbage, drop them.
    func purgeExpiredConfirmations(now: Date = Date()) async throws -> Int {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM pending_confirmations WHERE expires_at <= ?", arguments: [now])
            return db.changesCount
        }
    }

    // MARK: - kv / meta

    func setValue(_ value: String?, forKey key: String) async throws {
        try await pool.write { db in
            if value == nil {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
                return
            }
            try db.execute(
                sql: """
                INSERT INTO kv (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    func getValue(forKey key: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    // MARK: - Context assembly (FR-14)

    /// Recent session turns plus FTS-relevant fragments from older history,
    /// capped by the configured character budget.
    func buildContext(
        chatId: Int64,
        maxMessages: Int,
        budgetChars: Int?,
        systemPrompt: String?
    ) async throws -> [ChatMessage] {
        var context: [ChatMessage] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            context.append(.system(systemPrompt))
        }
        let turns = try await recentMessages(chatId: chatId, limit: maxMessages)

        if let budgetChars {
            let recentChars = turns.reduce(0) { $0 + $1.content.count }
            let fragmentBudget = budgetChars - recentChars
            if fragmentBudget > 0 {
                let terms = turnTerms(turns)
                if !terms.isEmpty {
                    // Fragments must add information: skip rows already shown as recent turns.
                    let hits = try await search(query: terms, limit: 6)
                        .filter { hit in !turns.contains { turn in turn.content == hit.content } }
                        .prefix(3)
                    let joined = hits.map(\.snippet).joined(separator: "\n— ")
                    let fragments = joined.truncate(toBudget: fragmentBudget)
                    if !fragments.isEmpty {
                        context.append(.system("[контекст из истории]\n\(fragments)"))
                    }
                }
            }
        }
        context.append(contentsOf: turns)
        return context
    }

    /// Terms from the latest user turn: bm25 ranks rare words above noisy
    /// common ones, so the newest request drives which history resurfaces.
    private func turnTerms(_ messages: [ChatMessage]) -> String {
        guard let lastUser = messages.last(where: { $0.role == "user" }) else { return "" }
        var words: [String] = []
        for piece in lastUser.content.split(separator: " ") {
            let word = String(piece)
            if word.count > 2 && !word.hasPrefix("/") {
                words.append(word)
            }
        }
        return words.prefix(8).joined(separator: " ")
    }

    // MARK: - Quota compression (FR-19)

    enum CompressionOutcome: Sendable, Equatable {
        case notNeeded
        case compressed(sessionsTouched: Int, deletedRaw: Int)
        case skipped(reason: String)
    }

    /// Automatic trigger after writes: crosses 85% of quota → compress on QoS .background.
    private func enforceQuotaIfNeeded() async {
        guard let provider, !compressionInFlight else { return }
        let size: Int64
        do {
            size = try await databaseFileSizeBytes
        } catch {
            return
        }
        let threshold = Double(quotaBytes) * StorageQuota.compressionThresholdShare
        guard Double(size) >= threshold else { return }

        compressionInFlight = true
        let model = modelName
        Task(priority: .background) {
            _ = await self.compressIfNeeded(provider: provider, model: model)
            self.compressionFinished()
        }
    }

    private func compressionFinished() {
        compressionInFlight = false
    }

    /// Compresses old history once total DB size crosses 85% of the quota:
    /// summarize old turns via the model, drop raw rows, incremental_vacuum.
    func compressIfNeeded(provider: any ModelProvider, model: String) async -> CompressionOutcome {
        guard !compacting else { return .skipped(reason: "already running") }
        compacting = true
        defer { compacting = false }
        do {
            let size = try await databaseFileSizeBytes
            let threshold = Double(quotaBytes) * StorageQuota.compressionThresholdShare
            guard Double(size) >= threshold else {
                logger?.debug("storage", "quota ok (\(size)/\(quotaBytes))")
                return .notNeeded
            }
            logger?.info("storage", "quota threshold hit (\(size)/\(quotaBytes)), compressing")

            let targetBytes = Int64(Double(quotaBytes) * 0.5)
            var touchedSessions = 0
            var deletedRawTotal = 0
            var exhausted = false

            while !exhausted {
                let sizeNow = try await databaseFileSizeBytes
                if sizeNow <= targetBytes { break }

                let victimCandidate = try await oldestCompressibleSession()
                guard let victim = victimCandidate else { break }

                let summaryCandidate = try await summarizeSession(
                    chatId: victim.chatId,
                    keepLast: victim.keepCount,
                    provider: provider,
                    model: model
                )
                guard let summary = summaryCandidate else { break }

                let removedCount = try await deleteOldRowsInsertingSummary(
                    chatId: victim.chatId,
                    keepLast: victim.keepCount,
                    summary: summary
                )
                touchedSessions += 1
                deletedRawTotal += removedCount
                if removedCount == 0 { exhausted = true }
            }

            try await runIncrementalVacuum()
            lastCompressionAt = Date()
            logger?.info("storage", "compression done: \(touchedSessions) session(s), \(deletedRawTotal) row(s)")
            return .compressed(sessionsTouched: touchedSessions, deletedRaw: deletedRawTotal)
        } catch {
            logger?.error("storage", "compression failed (ignored): \(error)")
            return .skipped(reason: "\(error)")
        }
    }

    private struct Victim: Sendable {
        let chatId: Int64
        let keepCount: Int
    }

    /// Oldest session whose history still has something worth summarizing.
    private func oldestCompressibleSession() async throws -> Victim? {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT s.chat_id AS chat_id, (
                    SELECT COUNT(*) FROM messages m WHERE m.session_id = s.chat_id
                ) AS cnt
                FROM sessions s
                ORDER BY s.created_at ASC
                LIMIT 10
                """
            )
            for row in rows {
                let chatId: Int64 = row["chat_id"]
                let count: Int = row["cnt"] ?? 0
                if count > 6 {
                    return Victim(chatId: chatId, keepCount: 4)
                }
            }
            return nil
        }
    }

    /// Summarizes every turn except the last `keepLast` into one paragraph.
    private func summarizeSession(
        chatId: Int64,
        keepLast: Int,
        provider: any ModelProvider,
        model: String
    ) async throws -> String? {
        let total = try await messageCount(chatId: chatId)
        if total <= keepLast { return nil }

        let olderCount = total - keepLast
        let lines: [String] = try await pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT role || ': ' || content FROM messages WHERE session_id = ? ORDER BY id ASC LIMIT ?",
                arguments: [chatId, olderCount]
            )
        }
        if lines.isEmpty { return nil }

        let transcript = lines.joined(separator: "\n").truncate(toBudget: 6000)
        let prompt = ChatMessage.system(
            "Сожми историю диалога в краткую сводку для памяти ассистента: факты, решения, договорённости. Только сводка, без вступлений."
        )
        let user = ChatMessage.user(transcript)

        var finalText: String?
        for try await delta in provider.streamChat(model: model, messages: [prompt, user], keepAliveSeconds: 0) {
            if case .final(let text, _) = delta { finalText = text }
        }
        let trimmed = finalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        return "[сводка истории] \(trimmed)".truncate(toBudget: 2000)
    }

    /// Deletes summarized raw rows and appends the summary inside one transaction.
    private func deleteOldRowsInsertingSummary(
        chatId: Int64,
        keepLast: Int,
        summary: String
    ) async throws -> Int {
        try await pool.write { db in
            let removableCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM (
                    SELECT id FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT -1 OFFSET ?
                )
                """,
                arguments: [chatId, keepLast]
            ) ?? 0
            if removableCount == 0 { return 0 }

            try db.execute(
                sql: """
                DELETE FROM messages WHERE session_id = ? AND id NOT IN (
                    SELECT id FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?
                )
                """,
                arguments: [chatId, chatId, keepLast]
            )
            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                arguments: [chatId, "assistant", summary, Date()]
            )
            return removableCount
        }
    }

    func runIncrementalVacuum() async throws {
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA incremental_vacuum(64)")
        }
    }

    /// Short lines for /status: database size and quota state.
    func statusLines() async -> [String] {        let size = (try? await databaseFileSizeBytes) ?? 0
        if size == 0 { return [] }
        let share = Double(size) / Double(max(1, quotaBytes))
        let percent = Int((share * 100).rounded())
        let stamp = lastCompressionAt.map { ISO8601DateFormatter().string(from: $0) } ?? "никогда"
        return [
            "db size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) (\(percent)% квоты)",
            "compression last run: \(stamp)",
        ]
    }

    /// Test/introspection hook: whether the given table (or virtual table) exists.
    func tableExists(_ name: String) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = ?)",
                arguments: [name]
            ) ?? false
        }
    }

    /// One hour of hygiene: checkpoint WAL to zero bytes, trim free pages, update planner stats,
    /// drop expired HITL requests.
    func performMaintenance() async {
        _ = try? await purgeExpiredConfirmations()
        do {
            try await pool.writeWithoutTransaction { db in
                do {
                    try db.checkpoint(.truncate)
                } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
                    logger?.info("maintenance", "wal_checkpoint busy, will retry next tick")
                }
                try db.execute(sql: "PRAGMA incremental_vacuum(64)")
                try db.execute(sql: "PRAGMA optimize")
            }
        } catch {
            logger?.error("maintenance", "tick failed (ignored): \(error)")
        }
    }
}

private extension StringProtocol {
    func truncate(toBudget budget: Int) -> String {
        if count <= budget { return String(self) }
        let cut = index(startIndex, offsetBy: Swift.max(0, budget - 1))
        return String(self[..<cut]) + "…"
    }
}
