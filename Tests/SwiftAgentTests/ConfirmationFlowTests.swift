import Foundation
import Testing
@testable import SwiftAgent

/// HITL roundtrip over a real SQLite database (FR-23).
@Suite struct ConfirmationFlowTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-hitl-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func insertReadDeleteRoundtrip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseManager(url: dir.appendingPathComponent("t.sqlite"))

        let id = try await db.insertPendingConfirmation(
            chatId: 42,
            messageId: nil,
            command: "rm -rf build",
            ttl: 600
        )
        #expect(id > 0)

        let pending = try await db.pendingConfirmation(id: id, chatId: 42)
        #expect(pending?.command == "rm -rf build")
        #expect(pending?.chatId == 42)

        // Wrong chat must not see the request.
        let foreign = try await db.pendingConfirmation(id: id, chatId: 43)
        #expect(foreign == nil)

        let deleted = try await db.deletePendingConfirmation(id: id)
        #expect(deleted)
        #expect(try await db.pendingConfirmation(id: id, chatId: 42) == nil)
        #expect(try await !db.deletePendingConfirmation(id: id))
    }

    @Test func expiredRequestIsInvisibleAndPurgeRemovesIt() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseManager(url: dir.appendingPathComponent("t.sqlite"))

        _ = try await db.insertPendingConfirmation(
            chatId: 1,
            messageId: nil,
            command: "shutdown now",
            ttl: -1 // already expired
        )
        #expect(try await db.pendingConfirmation(id: 1, chatId: 1) == nil)

        let purged = try await db.purgeExpiredConfirmations()
        #expect(purged >= 1)
    }

    @Test func agentResolveApprovesThenConsumes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseManager(url: dir.appendingPathComponent("t.sqlite"))
        var config = AgentConfig.default
        config.telegramAllowlist = [100]
        let agent = AgentActor(config: config, configURL: dir.appendingPathComponent("config.json"), state: FileStateStore(directory: dir), database: db)

        let id = try await db.insertPendingConfirmation(
            chatId: 7,
            messageId: nil,
            command: "rm -rf /tmp/x",
            ttl: 60
        )

        let approved = await agent.resolveConfirmation(id: id, chatId: 7, senderId: 100, approve: true)
        #expect(approved == .approved(command: "rm -rf /tmp/x"))

        // The request is consumed: second resolve finds nothing.
        let again = await agent.resolveConfirmation(id: id, chatId: 7, senderId: 100, approve: false)
        #expect(again == .ignored)
        #expect(try await db.pendingConfirmation(id: id, chatId: 7) == nil)
    }

    @Test func agentResolveCancelsCountsDenial() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try DatabaseManager(url: dir.appendingPathComponent("t.sqlite"))
        var config = AgentConfig.default
        config.telegramAllowlist = [100]
        let agent = AgentActor(config: config, configURL: dir.appendingPathComponent("config.json"), state: FileStateStore(directory: dir), database: db)

        let id = try await db.insertPendingConfirmation(chatId: 9, messageId: nil, command: "dd if=/dev/zero of=x", ttl: 60)
        let resolution = await agent.resolveConfirmation(id: id, chatId: 9, senderId: 100, approve: false)
        #expect(resolution == .cancelled)

        let status = await agent.statusText()
        #expect(status.contains("confirmations: 0 requested"))
    }
}
