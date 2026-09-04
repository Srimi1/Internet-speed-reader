import Foundation

public struct ThroughputSample: Sendable, Equatable {
    public let downMbps: Double
    public let upMbps: Double
    public let interfaceName: String
    public let at: ContinuousClock.Instant
    /// True when a speed test was running, so the UI can shade the spike it caused.
    public let duringTest: Bool

    public init(
        downMbps: Double,
        upMbps: Double,
        interfaceName: String,
        at: ContinuousClock.Instant,
        duringTest: Bool = false
    ) {
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.interfaceName = interfaceName
        self.at = at
        self.duringTest = duringTest
    }
}

/// Turns cumulative interface counters into a rate, with every trap handled explicitly.
///
/// The rate is always bytes divided by *measured* elapsed time, never by the nominal
/// tick interval. Timer coalescing and App Nap make ticks land late by design, so
/// assuming 1.0 s would over-report by whatever the drift was.
public struct ThroughputCalculator: Sendable {
    /// Above this the sample is nonsense and gets discarded rather than shown.
    public static let sanityCeilingMbps: Double = 50_000
    /// Gaps longer than this mean the process was napped or the machine slept.
    public static let staleGapSeconds: Double = 5.0
    /// Below this the division amplifies jitter too much to be meaningful.
    public static let minimumIntervalSeconds: Double = 0.2

    public enum Outcome: Sendable, Equatable {
        case rate(downMbps: Double, upMbps: Double)
        /// Discard this reading and start again from the new counters.
        case rebaseline(reason: RebaselineReason)
        /// Too soon since the last reading; keep the existing baseline.
        case tooSoon
    }

    public enum RebaselineReason: String, Sendable, Equatable {
        case counterWentBackwards
        case staleGap
        case implausibleRate
    }

    public init() {}

    public func evaluate(
        previous: IFCounters,
        current: IFCounters,
        elapsedSeconds: Double
    ) -> Outcome {
        guard elapsedSeconds >= Self.minimumIntervalSeconds else { return .tooSoon }
        guard elapsedSeconds <= Self.staleGapSeconds else { return .rebaseline(reason: .staleGap) }

        // 64-bit counters cannot legitimately wrap in any human timeframe, so a decrease
        // means the interface was reset (Wi-Fi toggled, dock/undock, VPN up/down).
        guard current.rx >= previous.rx, current.tx >= previous.tx else {
            return .rebaseline(reason: .counterWentBackwards)
        }

        let downMbps = Double(current.rx - previous.rx) * 8.0 / 1_000_000.0 / elapsedSeconds
        let upMbps = Double(current.tx - previous.tx) * 8.0 / 1_000_000.0 / elapsedSeconds

        guard downMbps <= Self.sanityCeilingMbps, upMbps <= Self.sanityCeilingMbps else {
            return .rebaseline(reason: .implausibleRate)
        }

        return .rate(downMbps: downMbps, upMbps: upMbps)
    }
}
