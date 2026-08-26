import Foundation

/// flock-based single instance guard. A second daemon exits immediately:
/// two getUpdates pollers on one token cause endless HTTP 409 cycles.
final class SingleInstanceLock: @unchecked Sendable {
    private let fileURL: URL
    private var handle: FileHandle?

    init(stateDirectory: URL? = nil) {
        let dir = stateDirectory ?? Paths.stateDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("agent.lock")
    }

    /// Returns false when another instance holds the lock.
    func acquire() -> Bool {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: fileURL.path) else { return false }
        let fd = fh.fileDescriptor
        let rc = flock(fd, LOCK_EX | LOCK_NB)
        if rc != 0 {
            try? fh.close()
            return false
        }
        handle = fh
        return true
    }

    func release() {
        if let handle {
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
            self.handle = nil
        }
    }
}
