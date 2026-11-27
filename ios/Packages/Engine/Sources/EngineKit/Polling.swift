import Foundation
import Relay

/// The pause before a screen's next relay check (SPEC.md 8.1): `base` after one that went;
/// after errors, doubling up to `cap`, with ±20 % jitter, and never inside the rate-limit
/// window. A final answer stops the checks for good.
public struct PollBackoff: Sendable {
    public let base: Int64
    public let cap: Int64
    private let random: @Sendable () -> Double
    private var failures = 0
    public private(set) var stopped = false

    public init(base: Int64, cap: Int64 = 60_000, random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.base = base
        self.cap = cap
        self.random = random
    }

    /// A final answer: asking again gets the same (any `4xx` but `408` and `429`, a clock the
    /// relay refuses, no keys).
    public static func isFinal(_ error: Error) -> Bool {
        guard let e = error as? RelayError else { return false }
        switch e {
        case .rateLimited, .transport, .unavailable: return false
        case .clockSkew, .noKeys: return true
        case .http, .conflict: return (400..<500).contains(e.status) && e.status != 408
        }
    }

    /// The pause in ms after a check that ended with `error` (nil: it went); nil to stop.
    public mutating func after(_ error: Error?, window: Int64) -> Int64? {
        if let error {
            if Self.isFinal(error) {
                stopped = true
                return nil
            }
            failures += 1
        } else {
            failures = 0
        }
        let pause = failures == 0 ? base : min(cap, base << Int64(min(failures, 16)))
        let jittered = Int64(Double(pause) * (0.8 + 0.4 * random()))
        return max(jittered, window)
    }
}
