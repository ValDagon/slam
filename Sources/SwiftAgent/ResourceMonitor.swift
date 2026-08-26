import Foundation

/// Self-observation of the daemon process: RSS and CPU time, sampled on demand.
/// Uses proc_pidinfo/proc_taskinfo — no external tools, no extra processes.
enum ResourceMonitor {
    struct Sample: Sendable, Equatable {
        /// Resident set size in bytes.
        let residentBytes: Int
        /// Total CPU seconds burned since process start (user+system, microseconds).
        let cpuSeconds: Double
        /// Wall-clock seconds since process start.
        let uptimeSeconds: Double

        /// Average CPU load over the whole lifetime, in percent of one core.
        var avgCPUPercent: Double {
            guard uptimeSeconds > 0 else { return 0 }
            return cpuSeconds / uptimeSeconds * 100
        }

        var rssMB: Double { Double(residentBytes) / 1_048_576 }
    }

    static func sample(uptime: TimeInterval) -> Sample? {
        var taskInfo = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &taskInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: 1) { intPtr in
                proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, intPtr, Int32(MemoryLayout<proc_taskinfo>.size))
            }
        }
        guard result == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return Sample(
            residentBytes: Int(taskInfo.pti_resident_size),
            cpuSeconds: Double(taskInfo.pti_total_user + taskInfo.pti_total_system) / 1_000_000,
            uptimeSeconds: uptime
        )
    }
}
