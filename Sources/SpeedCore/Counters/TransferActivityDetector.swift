import Foundation

/// Decides whether one direction is actually transferring, so the readout can emphasise
/// it while it happens.
///
/// Entry and exit are measured on the SAME statistic — bytes moved inside a trailing
/// window — with different thresholds and dwell times. Mixing a byte-volume entry with an
/// instantaneous-rate exit produces a detector that latches on and never releases when the
/// machine's idle chatter sits near the exit rate.
public struct TransferActivityDetector: Sendable {
    public enum State: String, Sendable, Equatable {
        case idle
        case active
    }

    public struct Thresholds: Sendable, Equatable {
        /// Bytes inside the window that mark the start of a transfer. About 1 Mbps
        /// sustained, or one burst; comfortably above ordinary background chatter.
        public var entryBytes: Double
        /// Bytes inside the window below which the transfer is considered finished.
        /// Roughly a third of entry, so the two never overlap.
        public var exitBytes: Double
        public var windowSeconds: Double
        /// Held below the exit threshold for this long before releasing. Long enough to
        /// ride out the silent pauses in a streamed API response.
        public var exitSeconds: Double
        /// Shortest time the active state can last, so a burst cannot flicker the display.
        public var minimumActiveSeconds: Double

        public init(
            entryBytes: Double = 384_000,
            exitBytes: Double = 128_000,
            windowSeconds: Double = 3,
            exitSeconds: Double = 8,
            minimumActiveSeconds: Double = 3
        ) {
            self.entryBytes = entryBytes
            self.exitBytes = exitBytes
            self.windowSeconds = windowSeconds
            self.exitSeconds = exitSeconds
            self.minimumActiveSeconds = minimumActiveSeconds
        }
    }

    private struct Entry {
        let bytes: Double
        let at: ContinuousClock.Instant
    }

    public let thresholds: Thresholds
    public private(set) var state: State = .idle
    private var window: [Entry] = []
    private var activeSince: ContinuousClock.Instant?
    private var belowExitSince: ContinuousClock.Instant?

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// Feeds one measured interval. `activityMbps` is the direction's activity rate and
    /// `elapsedSeconds` the measured time it covers, so a slow sampling cadence
    /// contributes its full weight instead of counting as a single tick.
    @discardableResult
    public mutating func update(
        activityMbps: Double,
        elapsedSeconds: Double,
        now: ContinuousClock.Instant
    ) -> State {
        let rate = activityMbps.isFinite ? max(0, activityMbps) : 0
        let elapsed = elapsedSeconds.isFinite && elapsedSeconds > 0 ? elapsedSeconds : 1
        let windowSeconds = thresholds.windowSeconds
        var entries = window
        entries.append(Entry(bytes: rate * 1_000_000 / 8 * elapsed, at: now))
        entries.removeAll { now.seconds(since: $0.at) > windowSeconds }
        window = entries
        let bytes = entries.reduce(0) { $0 + $1.bytes }

        switch state {
        case .idle:
            belowExitSince = nil
            if bytes >= thresholds.entryBytes {
                state = .active
                activeSince = now
            }
        case .active:
            if bytes > thresholds.exitBytes {
                belowExitSince = nil
                break
            }
            let since = belowExitSince ?? now
            belowExitSince = since
            let heldLongEnough = activeSince.map { now.seconds(since: $0) >= thresholds.minimumActiveSeconds } ?? true
            if now.seconds(since: since) >= thresholds.exitSeconds, heldLongEnough {
                state = .idle
                activeSince = nil
                belowExitSince = nil
            }
        }
        return state
    }

    /// How long the detector has been idle, for callers that must wait for real quiet.
    public func idleSeconds(now: ContinuousClock.Instant) -> Double {
        guard state == .idle else { return 0 }
        guard let last = window.last?.at else { return .infinity }
        return now.seconds(since: last)
    }

    public mutating func reset() {
        state = .idle
        window.removeAll()
        activeSince = nil
        belowExitSince = nil
    }
}
