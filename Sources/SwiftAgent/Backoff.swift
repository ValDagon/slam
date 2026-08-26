import Foundation

/// Exponential backoff with full jitter (AWS-style).
///
/// Delay sequence: base, base*2, base*4, ... capped at `maxDelay`.
/// The actual sleep is a uniform random value in `0...currentDelay`
/// (full jitter), which avoids synchronized restart storms when many
/// clients retry at once. A success resets the delay to `base`.
struct BackoffCalculator: Sendable {
    let base: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double

    private(set) var currentDelay: TimeInterval

    init(base: TimeInterval = 2, maxDelay: TimeInterval = 300, multiplier: Double = 2) {
        precondition(base > 0 && maxDelay >= base && multiplier >= 1)
        self.base = base
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.currentDelay = base
    }

    /// Returns the next sleep interval and advances the sequence.
    mutating func next(randomSource: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        let jittered = currentDelay * randomSource()
        currentDelay = min(currentDelay * multiplier, maxDelay)
        return jittered
    }

    func peekNextDelay() -> TimeInterval { currentDelay }

    mutating func reset() {
        currentDelay = base
    }
}
