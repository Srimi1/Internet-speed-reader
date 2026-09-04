import Foundation

public struct ThroughputSlice: Sendable, Equatable {
    public let mbps: Double
    public let secondsSincePhaseStart: Double

    public init(mbps: Double, secondsSincePhaseStart: Double) {
        self.mbps = mbps
        self.secondsSincePhaseStart = secondsSincePhaseStart
    }
}

public struct ThroughputSummary: Sendable, Equatable {
    /// The headline number, a trimmed mean of the steady-state slices.
    public let mbps: Double
    /// Total bytes over total seconds; a useful cross-check that cannot be skewed by trimming.
    public let meanMbps: Double
    /// 95th percentile slice.
    public let peakMbps: Double
    public let sliceCount: Int
    public let quality: Quality

    public enum Quality: String, Sendable, Equatable {
        case good
        /// Enough to report, but the phase was short enough that the number is rough.
        case shortSample
    }
}

public enum ThroughputAggregationError: Error, Equatable, Sendable {
    case insufficientData(slices: Int)
}

/// Turns a timeline of 100 ms slices into one headline number.
public struct ThroughputAggregator: Sendable {
    /// TCP slow start plus the socket buffer filling means the first stretch of any
    /// transfer is not representative. Discarding it is what makes the result comparable
    /// to other speed tests rather than systematically low.
    public static let warmUpSeconds: Double = 1.5
    public static let minimumSlices = 10
    public static let shortSampleThreshold = 30
    /// Drop the slowest 30 percent (ramp and stalls) and the fastest 10 percent
    /// (callback coalescing can bunch bytes into one slice and overstate it).
    public static let trimLowest = 0.30
    public static let trimHighest = 0.10

    public init() {}

    public func summarize(_ slices: [ThroughputSlice], totalBytes: UInt64, totalSeconds: Double) throws -> ThroughputSummary {
        let steady = slices.filter { $0.secondsSincePhaseStart >= Self.warmUpSeconds }
        let usable = steady.count >= Self.minimumSlices ? steady : Array(slices.dropFirst(3))

        guard usable.count >= Self.minimumSlices else {
            throw ThroughputAggregationError.insufficientData(slices: usable.count)
        }

        let sorted = usable.map(\.mbps).sorted()
        let lowerBound = Int((Double(sorted.count) * Self.trimLowest).rounded(.down))
        let upperBound = sorted.count - Int((Double(sorted.count) * Self.trimHighest).rounded(.down))
        let trimmed = Array(sorted[lowerBound..<max(lowerBound + 1, upperBound)])

        let headline = trimmed.reduce(0, +) / Double(trimmed.count)
        let mean = totalSeconds > 0 ? Double(totalBytes) * 8 / 1e6 / totalSeconds : 0
        let peak = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        return ThroughputSummary(
            mbps: headline,
            meanMbps: mean,
            peakMbps: peak,
            sliceCount: usable.count,
            quality: usable.count < Self.shortSampleThreshold ? .shortSample : .good
        )
    }
}
