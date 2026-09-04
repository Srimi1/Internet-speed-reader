import Foundation

/// Monotonic time + sleeping, injected everywhere so tests can drive the clock by hand.
///
/// Never use `Date` for elapsed-time math in this project: it moves when NTP corrects
/// the system clock, which would silently corrupt every throughput number.
public protocol TimeSource: Sendable {
    /// Monotonic "now". Survives clock adjustment and sleep.
    func now() -> ContinuousClock.Instant
    /// Wall-clock "now", for stamping records a human will read.
    func wallClock() -> Date
    func sleep(for duration: Duration, tolerance: Duration?) async throws
}

public extension TimeSource {
    func sleep(for duration: Duration) async throws {
        try await sleep(for: duration, tolerance: duration / 5)
    }
}

public struct SystemTimeSource: TimeSource {
    public init() {}

    public func now() -> ContinuousClock.Instant { ContinuousClock.now }

    public func wallClock() -> Date { Date() }

    public func sleep(for duration: Duration, tolerance: Duration?) async throws {
        try await Task.sleep(for: duration, tolerance: tolerance)
    }
}

public extension Duration {
    /// Duration -> seconds as Double, without losing sub-second precision.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

public extension ContinuousClock.Instant {
    /// Seconds elapsed since `start`. Negative if `start` is in the future.
    func seconds(since start: ContinuousClock.Instant) -> Double {
        (self - start).seconds
    }
}
