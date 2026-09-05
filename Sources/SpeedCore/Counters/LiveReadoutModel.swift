import Foundation

/// Decides what the menu bar and panel show for the live meter, including how long a
/// missing reading is tolerated before the numbers are replaced by a dash.
///
/// Pure and clock-injected so every timing rule is testable without a running sampler.
/// v1 blanked the readout on every rebaseline, which made ordinary events (a late tick,
/// one failed counter read) look like the app had died.
public struct LiveReadoutModel: Sendable {
    public enum Freshness: String, Sendable, Equatable {
        /// A sample arrived within the expected window.
        case fresh
        /// No sample right now, but the last one is recent enough to keep showing.
        case holding
        /// Nothing trustworthy to show.
        case unavailable
    }

    public struct Presentation: Sendable, Equatable {
        public var downMbps: Double
        public var upMbps: Double
        public var freshness: Freshness
        public var message: String

        public init(downMbps: Double, upMbps: Double, freshness: Freshness, message: String) {
            self.downMbps = downMbps
            self.upMbps = upMbps
            self.freshness = freshness
            self.message = message
        }

        /// True while there is a real number on screen, held or fresh.
        public var hasReading: Bool { freshness != .unavailable }
    }

    /// How long the last reading stays on screen when samples stop arriving.
    ///
    /// Derived from the sampler's own staleness rule plus one cadence of recovery slack,
    /// so the readout can never blank while the sampler still considers a gap normal.
    public static func holdSeconds(expectedIntervalSeconds: Double) -> Double {
        let interval = expectedIntervalSeconds.isFinite && expectedIntervalSeconds > 0 ? expectedIntervalSeconds : 1
        return ThroughputCalculator.maximumGapSeconds(expectedIntervalSeconds: interval) + interval
    }

    private var downMbps: Double = 0
    private var upMbps: Double = 0
    private var hasValue = false
    private var lastSampleAt: ContinuousClock.Instant?
    private var holdUntil: ContinuousClock.Instant?
    private var message: String
    /// Fires the recovery request once per staleness episode. Without this latch the
    /// caller's refresh loop, which runs faster than the sampling cadence, would drop the
    /// monitor's baseline before it could ever build a delta.
    private var rebaselineRequested = false

    public init(message: String = "Waiting for a reading") {
        self.message = message
    }

    /// The instant of the most recent sample, retained across holds.
    public var lastSampleInstant: ContinuousClock.Instant? { lastSampleAt }

    public mutating func sample(downMbps: Double, upMbps: Double, at now: ContinuousClock.Instant) {
        self.downMbps = downMbps.isFinite ? max(0, downMbps) : 0
        self.upMbps = upMbps.isFinite ? max(0, upMbps) : 0
        hasValue = true
        lastSampleAt = now
        holdUntil = nil
        rebaselineRequested = false
        message = "Live traffic · all apps"
    }

    /// A reading did not arrive. Transient reasons keep the last numbers on screen for a
    /// grace period; terminal reasons clear immediately because the source itself is gone.
    public mutating func unavailable(
        _ reason: LiveThroughputUnavailableReason,
        at now: ContinuousClock.Instant,
        expectedIntervalSeconds: Double
    ) {
        message = Self.message(for: reason)
        switch reason {
        case .starting, .stale, .counterUnavailable:
            guard hasValue else {
                clear(message: message)
                return
            }
            if holdUntil == nil {
                holdUntil = now.advanced(by: .seconds(Self.holdSeconds(expectedIntervalSeconds: expectedIntervalSeconds)))
            }
        case .noInterface, .paused:
            clear(message: message)
        }
    }

    /// Terminal reset for lifecycle events: sleep, interface change, shutdown.
    public mutating func reset(message: String) {
        clear(message: message)
    }

    private mutating func clear(message: String) {
        downMbps = 0
        upMbps = 0
        hasValue = false
        lastSampleAt = nil
        holdUntil = nil
        rebaselineRequested = false
        self.message = message
    }

    public func presentation(now: ContinuousClock.Instant) -> Presentation {
        guard hasValue else {
            return Presentation(downMbps: 0, upMbps: 0, freshness: .unavailable, message: message)
        }
        guard let holdUntil else {
            return Presentation(downMbps: downMbps, upMbps: upMbps, freshness: .fresh, message: message)
        }
        if now < holdUntil {
            return Presentation(downMbps: downMbps, upMbps: upMbps, freshness: .holding, message: message)
        }
        return Presentation(downMbps: 0, upMbps: 0, freshness: .unavailable, message: message)
    }

    /// True at most once per staleness episode, when the reading has been missing longer
    /// than the sampler's own gap allowance and the monitor should be re-baselined.
    public mutating func needsRebaseline(now: ContinuousClock.Instant, expectedIntervalSeconds: Double) -> Bool {
        guard !rebaselineRequested else { return false }
        let limit = ThroughputCalculator.maximumGapSeconds(expectedIntervalSeconds: expectedIntervalSeconds)
        let reference = lastSampleAt ?? holdUntil
        guard let reference, now.seconds(since: reference) > limit else { return false }
        rebaselineRequested = true
        return true
    }

    private static func message(for reason: LiveThroughputUnavailableReason) -> String {
        switch reason {
        case .starting: return "Starting the live meter"
        case .noInterface: return "No network interface"
        case .counterUnavailable: return "Interface counters unavailable"
        case .paused: return "Paused while the Mac sleeps"
        case .stale: return "Waiting for a fresh reading"
        }
    }
}
