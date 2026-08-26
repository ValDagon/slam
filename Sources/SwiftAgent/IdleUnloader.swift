import Foundation

/// Unloads Ollama weights after a period of inactivity (FR-15).
///
/// Every chat request already sends keep_alive: 0, so this is a safety net
/// for providers that keep state server-side. The tick is one long Task.sleep
/// per minute — no busy polling, idle CPU stays ~0%.
actor IdleUnloader {
    private let provider: OllamaClient
    private let modelName: String
    private let idleTimeout: TimeInterval
    private let logger: FileLogger
    private var lastUsedAt = Date()
    private var running = false

    init(provider: OllamaClient, modelName: String, idleMinutes: Int, logger: FileLogger) {
        self.provider = provider
        self.modelName = modelName
        self.idleTimeout = TimeInterval(idleMinutes * 60)
        self.logger = logger
    }

    nonisolated func start() {
        Task(priority: .utility) { await runLoop() }
    }

    func noteUsed() {
        lastUsedAt = Date()
    }

    /// Test hook: runs exactly one check instead of the endless loop.
    func tick(now: Date = Date()) async {
        guard now.timeIntervalSince(lastUsedAt) >= idleTimeout else { return }
        do {
            try await provider.unload(model: modelName)
            logger.info("unloader", "model \(modelName) unloaded after idle")
        } catch {
            // Unload failures are harmless: keep_alive: 0 already bounds VRAM.
            logger.info("unloader", "unload failed (ignored): \(error)")
        }
    }

    private func runLoop() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await tick()
        }
    }
}
