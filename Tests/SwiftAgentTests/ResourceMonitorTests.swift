import Testing
@testable import SwiftAgent

struct ResourceMonitorTests {
    @Test func sampleReturnsLiveMetrics() {
        guard let sample = ResourceMonitor.sample(uptime: 10) else {
            Issue.record("proc_pidinfo returned no task info")
            return
        }
        #expect(sample.residentBytes > 0)
        #expect(sample.cpuSeconds >= 0)
        // avg over 10s wall clock cannot exceed one core
        #expect(sample.avgCPUPercent <= 100)
        #expect(sample.rssMB < 500)
    }
}
