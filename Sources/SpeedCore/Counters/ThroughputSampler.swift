import Foundation

public struct ThroughputSample: Sendable, Equatable {
    public let downMbps: Double
    public let upMbps: Double
    public let interfaceName: String
    public let at: ContinuousClock.Instant
    /// True when a speed test was running, so the UI can shade the spike it caused.
    public let duringTest: Bool
    /// Used only to select the arrow and to emphasise a row; the displayed rate remains
    /// the measured byte rate.
    public let uploadActivityMbps: Double
    /// The same allowance applied to received bytes, so the acknowledgements of a large
    /// upload do not read as an active download.
    public let downloadActivityMbps: Double
    public let elapsedSeconds: Double

    public init(
        downMbps: Double,
        upMbps: Double,
        interfaceName: String,
        at: ContinuousClock.Instant,
        duringTest: Bool = false,
        uploadActivityMbps: Double? = nil,
        downloadActivityMbps: Double? = nil,
        elapsedSeconds: Double = 1
    ) {
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.interfaceName = interfaceName
        self.at = at
        self.duringTest = duringTest
        self.uploadActivityMbps = uploadActivityMbps ?? upMbps
        self.downloadActivityMbps = downloadActivityMbps ?? downMbps
        self.elapsedSeconds = elapsedSeconds
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
    /// Minimum stale threshold; intentional slow sampling needs a larger window.
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

    public static func maximumGapSeconds(expectedIntervalSeconds: Double) -> Double {
        let interval = expectedIntervalSeconds.isFinite && expectedIntervalSeconds > 0
            ? expectedIntervalSeconds : 1
        // A five-second low-power cadence normally lands just after five seconds. The
        // former fixed limit discarded every such reading and left the bar frozen.
        return max(staleGapSeconds, 3 * interval)
    }

    public func evaluate(
        previous: IFCounters,
        current: IFCounters,
        elapsedSeconds: Double,
        expectedIntervalSeconds: Double = 1
    ) -> Outcome {
        guard elapsedSeconds >= Self.minimumIntervalSeconds else { return .tooSoon }
        guard elapsedSeconds <= Self.maximumGapSeconds(expectedIntervalSeconds: expectedIntervalSeconds)
        else { return .rebaseline(reason: .staleGap) }

        // 64-bit counters cannot legitimately wrap in any human timeframe, so a decrease
        // means the interface was reset (Wi-Fi toggled, dock/undock, VPN up/down).
        guard current.rx >= previous.rx, current.tx >= previous.tx,
              current.txPackets >= previous.txPackets, current.rxPackets >= previous.rxPackets else {
            return .rebaseline(reason: .counterWentBackwards)
        }

        let downMbps = Double(current.rx - previous.rx) * 8.0 / 1_000_000.0 / elapsedSeconds
        let upMbps = Double(current.tx - previous.tx) * 8.0 / 1_000_000.0 / elapsedSeconds

        guard downMbps <= Self.sanityCeilingMbps, upMbps <= Self.sanityCeilingMbps else {
            return .rebaseline(reason: .implausibleRate)
        }

        return .rate(downMbps: downMbps, upMbps: upMbps)
    }

    /// Bytes per packet allowed for pure control traffic before a direction counts as
    /// carrying payload. Sized for an acknowledgement plus headers.
    public static let controlAllowanceBytesPerPacket: Double = 160

    /// Conservative evidence of upload payload, not a protocol parser. In particular,
    /// many ACKs can hide a small simultaneous upload inside this allowance. VPN/QUIC
    /// traffic can also exceed it. Never subtract this allowance from the shown speed.
    public static func uploadActivityMbps(
        previous: IFCounters,
        current: IFCounters,
        elapsedSeconds: Double
    ) -> Double {
        guard current.tx >= previous.tx, current.txPackets >= previous.txPackets else { return 0 }
        return activityMbps(
            bytes: current.tx - previous.tx,
            packets: current.txPackets - previous.txPackets,
            elapsedSeconds: elapsedSeconds
        )
    }

    /// The mirror of the upload allowance. A large upload generates a steady stream of
    /// small acknowledgements; without this the download row would light up during it.
    public static func downloadActivityMbps(
        previous: IFCounters,
        current: IFCounters,
        elapsedSeconds: Double
    ) -> Double {
        guard current.rx >= previous.rx, current.rxPackets >= previous.rxPackets else { return 0 }
        return activityMbps(
            bytes: current.rx - previous.rx,
            packets: current.rxPackets - previous.rxPackets,
            elapsedSeconds: elapsedSeconds
        )
    }

    private static func activityMbps(bytes: UInt64, packets: UInt64, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        let allowance = Double(packets) * controlAllowanceBytesPerPacket
        return max(0, Double(bytes) - allowance) * 8 / 1_000_000 / elapsedSeconds
    }
}

/// Keeps the same one-second half-life on AC, battery and low-power cadences.
public struct ThroughputSmoother: Sendable {
    private var previous: (down: Double, up: Double)?

    public init() {}

    public mutating func update(
        downMbps: Double,
        upMbps: Double,
        elapsedSeconds: Double
    ) -> (downMbps: Double, upMbps: Double) {
        let down = downMbps.isFinite ? max(0, downMbps) : 0
        let up = upMbps.isFinite ? max(0, upMbps) : 0
        guard let previous else {
            self.previous = (down, up)
            return (down, up)
        }
        let elapsed = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 1
        let weight = 1 - pow(0.5, elapsed)
        // Idle background chatter should read as measured, not as a decaying old transfer.
        let result = (
            down < ActiveDirectionSelector.entryMbps ? down : previous.down + (down - previous.down) * weight,
            up < ActiveDirectionSelector.entryMbps ? up : previous.up + (up - previous.up) * weight
        )
        self.previous = result
        return result
    }

    public mutating func reset() { previous = nil }
}
