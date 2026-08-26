import Testing
@testable import SwiftAgent

struct BackoffTests {
    @Test func delayGrowsAndCaps() {
        var b = BackoffCalculator(base: 2, maxDelay: 10)
        // Deterministic jitter source at max keeps the raw sequence visible.
        #expect(b.next(randomSource: { 1 }) == 2)
        #expect(b.peekNextDelay() == 4)
        #expect(b.next(randomSource: { 1 }) == 4)
        #expect(b.peekNextDelay() == 8)
        #expect(b.next(randomSource: { 1 }) == 8)
        // Cap reached: stays at 10.
        #expect(b.peekNextDelay() == 10)
        #expect(b.next(randomSource: { 1 }) == 10)
        #expect(b.next(randomSource: { 1 }) == 10)
    }

    @Test func fullJitterBounds() {
        var b = BackoffCalculator(base: 100, maxDelay: 300)
        var preCallDelay = 100.0
        for _ in 0..<200 {
            let delay = b.next()
            #expect(delay >= 0)
            // Jitter is drawn from the delay value before advancing, so a sample
            // never exceeds base, base*2, ... capped at maxDelay.
            #expect(delay <= preCallDelay * (1 + 1e-9))
            preCallDelay = min(preCallDelay * 2, 300)
        }
    }

    @Test func resetAfterSuccess() {
        var b = BackoffCalculator(base: 2, maxDelay: 300)
        _ = b.next(randomSource: { 1 })
        _ = b.next(randomSource: { 1 })
        #expect(b.peekNextDelay() > 2)
        b.reset()
        #expect(b.peekNextDelay() == 2)
    }

    @Test func zeroJitterYieldsZeroSleep() {
        var b = BackoffCalculator(base: 2, maxDelay: 300)
        #expect(b.next(randomSource: { 0 }) == 0)
    }
}
