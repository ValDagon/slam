import Foundation
import Testing
@testable import SwiftAgent

struct FileStateStoreTests {
    private func makeStore() -> (FileStateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-tests-\(UUID().uuidString)", isDirectory: true)
        return (FileStateStore(directory: dir), dir)
    }

    @Test func roundtripAndPersistenceAcrossInstances() throws {
        let (store1, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store1.get("tg_offset") == nil)
        try store1.set("tg_offset", "12345")

        // A new instance reads what was written by the previous process.
        let store2 = FileStateStore(directory: dir)
        #expect(store2.get("tg_offset") == "12345")
        try store2.set("tg_offset", "12346")
        #expect(store1.get("tg_offset") == "12346")
    }

    @Test func fileSizeIsReported() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.set("k", String(repeating: "x", count: 500))
        let size = store.fileSizeBytes()
        #expect(size != nil)
        #expect(size! > 400)
    }
}
