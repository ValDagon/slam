import Foundation

/// Persistent key-value state (Telegram update offset etc.).
/// Stage 1 uses a JSON file; stage 3 replaces this with SQLite behind the same protocol.
protocol StateStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String) throws
    func fileSizeBytes() -> Int?
}

struct FileStateStore: StateStore {
    let fileURL: URL

    private final class LockBox: @unchecked Sendable {
        let lock = NSLock()
    }

    private static let ioLock = LockBox()

    init(directory: URL? = nil, fileName: String = "state.json") {
        let dir = directory ?? Paths.stateDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(fileName)
    }

    func get(_ key: String) -> String? {
        Self.ioLock.lock.lock()
        defer { Self.ioLock.lock.unlock() }
        return readDict()[key]
    }

    func set(_ key: String, _ value: String) throws {
        Self.ioLock.lock.lock()
        defer { Self.ioLock.lock.unlock() }
        var dict = readDict()
        dict[key] = value
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    func fileSizeBytes() -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int
    }

    private func readDict() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }
}
