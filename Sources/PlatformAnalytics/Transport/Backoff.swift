import Foundation

/// Backoff exponentiel 5 s → 10 min avec jitter (moitié fixe, moitié aléatoire), C05 §2.6.
struct Backoff {
    static let initial: TimeInterval = 5
    static let maximum: TimeInterval = 600

    private(set) var failures = 0

    /// Délai avant la prochaine tentative, dans `[d/2, d]` avec `d = min(5 s × 2^échecs, 10 min)`.
    mutating func nextDelay(using generator: inout some RandomNumberGenerator) -> TimeInterval {
        let exponent = Double(min(failures, 16))
        let ceiling = min(Self.maximum, Self.initial * pow(2, exponent))
        failures += 1
        return ceiling / 2 + Double.random(in: 0...(ceiling / 2), using: &generator)
    }

    mutating func nextDelay() -> TimeInterval {
        var generator = SystemRandomNumberGenerator()
        return nextDelay(using: &generator)
    }

    mutating func reset() { failures = 0 }
}
