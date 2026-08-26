import Foundation

/// Structured log line: "timestamp level module message".
struct LogLine: Sendable {
    let level: LogLevel
    let module: String
    let message: String
    let timestamp: Date

    enum LogLevel: String, Sendable, Comparable {
        case debug, info, error

        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .error: return 2
            }
        }

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    func render() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        return "\(df.string(from: timestamp)) \(level.rawValue.uppercased()) [\(module)] \(message)"
    }
}

/// File + stderr logger. Rotation: when the file exceeds `maxBytes`,
/// it is renamed to `.1` (overwriting any previous `.1`).
final class FileLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: AppIdentity.loggerQueueLabel)
    private let logDirectory: URL
    private let logFileURL: URL
    private let maxBytes: Int
    private let minLevel: LogLine.LogLevel
    private let mirrorToStderr: Bool
    private var currentHandle: FileHandle?

    init(
        logDirectory: URL? = nil,
        minLevel: LogLine.LogLevel = .debug,
        mirrorToStderr: Bool? = nil,
        maxBytes: Int = 5 * 1024 * 1024
    ) {
        let dir = logDirectory ?? Self.defaultLogDirectory()
        // Under launchd stderr goes to a file anyway; the env flag avoids doubled lines.
        let mirror = mirrorToStderr ?? Self.shouldMirrorToStderr()
        self.logDirectory = dir
        self.logFileURL = dir.appendingPathComponent(AppIdentity.logFileName)
        self.maxBytes = maxBytes
        self.minLevel = minLevel
        self.mirrorToStderr = mirror
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        openHandle()
    }

    /// LaunchAgent plist sets `SLAM_QUIET_STDERR=1` so file logs are not doubled
    /// into launchd stdout/stderr. The old env name still works after the rebrand.
    static func shouldMirrorToStderr() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env[AppIdentity.quietStderrEnv] == "1" { return false }
        if env[AppIdentity.legacyQuietStderrEnv] == "1" { return false }
        return true
    }

    deinit {
        try? currentHandle?.close()
    }

    static func defaultLogDirectory() -> URL {
        Paths.logDirectoryURL()
    }

    func log(_ level: LogLine.LogLevel, _ module: String, _ message: String) {
        guard level >= minLevel else { return }
        let line = LogLine(level: level, module: module, message: message, timestamp: Date()).render()
        queue.async { [weak self] in
            guard let self else { return }
            if self.mirrorToStderr {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            self.write(line)
        }
    }

    func debug(_ module: String, _ message: String) { log(.debug, module, message) }
    func info(_ module: String, _ message: String) { log(.info, module, message) }
    func error(_ module: String, _ message: String) { log(.error, module, message) }

    /// Blocks until the line is written — use before `exit()` when async logging would be lost.
    func logSync(_ level: LogLine.LogLevel, _ module: String, _ message: String) {
        guard level >= minLevel else { return }
        let line = LogLine(level: level, module: module, message: message, timestamp: Date()).render()
        queue.sync { [self] in
            if mirrorToStderr {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            write(line)
        }
    }

    func flushSync() {
        queue.sync {}
    }

    private func write(_ line: String) {
        rotateIfNeeded()
        currentHandle?.write(Data((line + "\n").utf8))
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        closeHandle()
        let rotatedURL = logFileURL.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedURL)
        openHandle()
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        currentHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? currentHandle?.seekToEnd()
    }

    private func closeHandle() {
        try? currentHandle?.close()
        currentHandle = nil
    }
}

/// Global logger handle for modules that do not receive one explicitly.
nonisolated(unsafe) var sharedLogger: FileLogger = FileLogger(mirrorToStderr: true)
