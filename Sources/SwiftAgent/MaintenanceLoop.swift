import Foundation

/// Hourly storage hygiene (FR-20): wal_checkpoint(TRUNCATE), incremental_vacuum,
/// PRAGMA optimize — all at QoS .background. One long Task.sleep per hour, so
/// idle CPU stays ~0%. Compression is triggered by DatabaseManager itself.
actor MaintenanceLoop {
    private let database: DatabaseManager
    private let logger: FileLogger
    private var running = false

    init(database: DatabaseManager, logger: FileLogger) {
        self.database = database
        self.logger = logger
    }

    nonisolated func start() {
        Task(priority: .background) { await runLoop() }
    }

    /// Test hook: runs exactly one tick instead of the endless loop.
    func tick() async {
        await database.performMaintenance()
    }

    private func runLoop() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
            if Task.isCancelled { return }
            logger.debug("maintenance", "tick")
            await tick()
        }
    }
}
