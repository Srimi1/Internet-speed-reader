import Foundation

public struct ThroughputSlice: Sendable, Equatable {
    public let mbps: Double
    /// End of the measured interval, relative to the phase start.
    public let secondsSincePhaseStart: Double
    public let durationSeconds: Double

    public init(mbps: Double, secondsSincePhaseStart: Double, durationSeconds: Double = 0.1) {
        self.mbps = mbps
        self.secondsSincePhaseStart = secondsSincePhaseStart
        self.durationSeconds = durationSeconds
    }
}

public struct ThroughputSummary: Sendable, Equatable {
    /// Confirmed payload over the actual post-warm-up measurement time, including stalls.
    public let mbps: Double
    public let meanMbps: Double
    public let peakMbps: Double
    public let sliceCount: Int
    public let quality: Quality

    public enum Quality: String, Sendable, Equatable {
        case good, shortSample, dataLimited, variable, incomplete

        var severity: Int {
            switch self {
            case .good: 0
            case .variable: 1
            case .shortSample: 2
            case .dataLimited: 3
            case .incomplete: 4
            }
        }
    }
}

public enum ThroughputAggregationError: Error, Equatable, Sendable {
    case insufficientData(slices: Int)
}

public struct ThroughputAggregator: Sendable {
    public static let warmUpSeconds: Double = 1.5
    public static let minimumMeasurementSeconds: Double = 1
    public static let goodMeasurementSeconds: Double = 3
    /// Variation is computed over one-second windows, not bursty delegate callbacks.
    public static let variableCoefficient: Double = 0.25

    public init() {}

    public func summarize(_ slices: [ThroughputSlice], totalBytes: UInt64, totalSeconds: Double,
                          dataLimited: Bool = false, incomplete: Bool = false) throws -> ThroughputSummary {
        let measured = slices.compactMap { slice -> (rate: Double, duration: Double, end: Double)? in
            guard slice.mbps.isFinite, slice.mbps >= 0,
                  slice.durationSeconds.isFinite, slice.durationSeconds > 0,
                  slice.secondsSincePhaseStart.isFinite else { return nil }
            let end = min(slice.secondsSincePhaseStart, totalSeconds)
            let start = max(Self.warmUpSeconds, slice.secondsSincePhaseStart - slice.durationSeconds)
            let duration = end - start
            guard duration > 0 else { return nil }
            return (slice.mbps, duration, end)
        }
        let seconds = measured.reduce(0) { $0 + $1.duration }
        let megabits = measured.reduce(0) { $0 + $1.rate * $1.duration }
        guard totalSeconds.isFinite, totalSeconds > 0, totalBytes > 0,
              seconds + 1e-9 >= Self.minimumMeasurementSeconds, megabits > 0 else {
            throw ThroughputAggregationError.insufficientData(slices: measured.count)
        }
        let headline = megabits / seconds
        let mean = Double(totalBytes) * 8 / 1e6 / totalSeconds

        // Callback coalescing is not network variability. Aggregate consecutive seconds
        // before estimating variation and peak; preserve zero-rate windows throughout.
        var windows: [Int: (megabits: Double, seconds: Double)] = [:]
        for sample in measured {
            var start = sample.end - sample.duration
            while start < sample.end - 1e-9 {
                let index = Int(floor(start - Self.warmUpSeconds + 1e-9))
                let end = min(sample.end, Self.warmUpSeconds + Double(index + 1))
                let duration = end - start
                let previous = windows[index] ?? (0, 0)
                windows[index] = (previous.megabits + sample.rate * duration, previous.seconds + duration)
                start = end
            }
        }
        let rates = windows.values.filter { $0.seconds > 0 }.map { (rate: $0.megabits / $0.seconds, duration: $0.seconds) }
        let variance = rates.reduce(0) { $0 + pow($1.rate - headline, 2) * $1.duration } / seconds
        let quality: ThroughputSummary.Quality
        if incomplete { quality = .incomplete }
        else if dataLimited { quality = .dataLimited }
        else if seconds < Self.goodMeasurementSeconds { quality = .shortSample }
        else if sqrt(variance) / headline > Self.variableCoefficient { quality = .variable }
        else { quality = .good }

        let sorted = rates.map(\.rate).sorted()
        let peak = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return ThroughputSummary(mbps: headline, meanMbps: mean, peakMbps: peak,
                                 sliceCount: measured.count, quality: quality)
    }
}
