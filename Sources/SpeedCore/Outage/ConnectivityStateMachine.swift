import Foundation

/// The outage decision logic, as a pure value type: no clocks, no I/O, no tasks.
/// Everything time-dependent arrives as `now` on each event, which makes every rule
/// here testable by hand.
public struct ConnectivityStateMachine: Sendable, Equatable {
    // MARK: Tunables

    public struct Config: Sendable, Equatable {
        /// Two consecutive failures before declaring an outage; one success clears it.
        /// Asymmetric on purpose: recovery should feel instant, outages should not flap.
        public var failuresToConfirm = 2
        /// An unsatisfied path is trustworthy, but roaming between access points
        /// briefly unsatisfies it, so wait this long before going red.
        public var pathDebounce: Duration = .seconds(3)
        /// Only notify once an outage has really lasted; shorter blips stay silent.
        public var notifyAfter: Duration = .seconds(10)
        /// Outages shorter than this are noise and never reach the log.
        public var minimumLoggedDuration: Duration = .seconds(3)
        public var wakeGrace: Duration = .seconds(20)
        public var interfaceChangeGrace: Duration = .seconds(15)
        public var launchGrace: Duration = .seconds(10)
        public var onlineCadence: Duration = .seconds(15)
        public var degradedCadence: Duration = .seconds(2)
        public var backoffCadence: Duration = .seconds(30)
        public var failuresBeforeBackoff = 10

        public init() {}
    }

    // MARK: State

    public enum State: Sendable, Equatable {
        case unknown
        case online
        /// One failure seen; not yet an outage.
        case suspect(failures: Int)
        case down
        case captivePortal
        /// Sleeping, or a speed test is saturating the link. All events ignored.
        case suspended(reason: SuspendReason)
    }

    public enum SuspendReason: String, Sendable, Equatable {
        case sleep
        case speedTest
    }

    public enum Event: Sendable, Equatable {
        case launched
        case path(status: PathSnapshot.Status, reason: String?, interfaceName: String?, interfaceChanged: Bool)
        case probe(ProbeOutcome)
        case tick
        case willSleep
        case didWake
        case speedTestStarted
        case speedTestFinished(success: Bool)
        case alertsPausedUntilChanged
    }

    public enum Effect: Sendable, Equatable {
        case scheduleProbe(after: Duration)
        case openOutage(cause: OutageCause, start: Date, reason: String?, interfaceName: String?)
        case recordFailure(ProbeFailureKind)
        case closeOutage(at: Date, endReason: OutageEnd)
        case notifyDown
        case notifyUp
        case scheduleNotifyCheck(at: Date)
    }

    public private(set) var state: State = .unknown
    public private(set) var consecutiveFailures = 0
    /// Notifications are gated until this instant; the ledger is never gated, so the
    /// log stays honest even while banners are suppressed.
    public private(set) var graceUntil: ContinuousClock.Instant?
    public private(set) var outageStart: Date?
    public private(set) var notifiedForCurrentOutage = false
    public private(set) var alertsPaused = false

    private var firstFailureAt: Date?
    private var pathUnsatisfiedSince: ContinuousClock.Instant?
    private var currentInterface: String?

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func setAlertsPaused(_ paused: Bool) { alertsPaused = paused }

    // MARK: Transition

    public mutating func handle(
        _ event: Event,
        now: ContinuousClock.Instant,
        wallClock: Date
    ) -> [Effect] {
        // Suspended swallows everything except the events that lift the suspension.
        if case let .suspended(reason) = state {
            switch (event, reason) {
            case (.didWake, .sleep):
                return resume(now: now, grace: config.wakeGrace)
            case (.speedTestFinished(let success), .speedTest):
                var effects = resume(now: now, grace: .seconds(2))
                if success { effects += handle(.probe(.online(rttMs: nil, viaFallback: false)), now: now, wallClock: wallClock) }
                return effects
            default:
                return []
            }
        }

        switch event {
        case .launched:
            graceUntil = now.advanced(by: config.launchGrace)
            return [.scheduleProbe(after: .zero)]

        case .willSleep:
            var effects: [Effect] = []
            // Close any open outage now rather than leaving it running all night: we
            // cannot honestly time an outage across a sleep we were not awake for.
            if outageStart != nil {
                effects.append(.closeOutage(at: wallClock, endReason: .sleep))
                clearOutage()
            }
            state = .suspended(reason: .sleep)
            return effects

        case .didWake:
            return resume(now: now, grace: config.wakeGrace)

        case .speedTestStarted:
            state = .suspended(reason: .speedTest)
            return []

        case .speedTestFinished:
            return resume(now: now, grace: .seconds(2))

        case .alertsPausedUntilChanged:
            return []

        case let .path(status, reason, interfaceName, interfaceChanged):
            return handlePath(
                status: status, reason: reason, interfaceName: interfaceName,
                interfaceChanged: interfaceChanged, now: now, wallClock: wallClock
            )

        case let .probe(outcome):
            return handleProbe(outcome, now: now, wallClock: wallClock)

        case .tick:
            return handleTick(now: now, wallClock: wallClock)
        }
    }

    // MARK: Handlers

    private mutating func handlePath(
        status: PathSnapshot.Status,
        reason: String?,
        interfaceName: String?,
        interfaceChanged: Bool,
        now: ContinuousClock.Instant,
        wallClock: Date
    ) -> [Effect] {
        if interfaceChanged {
            graceUntil = now.advanced(by: config.interfaceChangeGrace)
            currentInterface = interfaceName
        }

        switch status {
        case .unsatisfied:
            // Debounce: a Wi-Fi roam unsatisfies the path for a moment, and turning the
            // bar red for it would be a false alarm several times a day.
            if pathUnsatisfiedSince == nil { pathUnsatisfiedSince = now }
            let elapsed = now.seconds(since: pathUnsatisfiedSince!)
            guard elapsed >= config.pathDebounce.seconds else {
                return [.scheduleProbe(after: config.pathDebounce)]
            }
            if outageStart == nil {
                let start = firstFailureAt ?? wallClock
                return openOutage(
                    cause: .pathUnsatisfied, start: start, reason: reason,
                    interfaceName: interfaceName, wallClock: wallClock
                )
            }
            return []

        case .satisfied, .requiresConnection, .unknown:
            pathUnsatisfiedSince = nil
            // A satisfied path is NOT proof of internet: a captive portal satisfies it,
            // so this only schedules a probe rather than declaring victory.
            return [.scheduleProbe(after: .milliseconds(300))]
        }
    }

    private mutating func handleProbe(
        _ outcome: ProbeOutcome,
        now: ContinuousClock.Instant,
        wallClock: Date
    ) -> [Effect] {
        switch outcome {
        case .online:
            var effects: [Effect] = []
            let wasDown = outageStart != nil
            if wasDown {
                effects.append(.closeOutage(at: wallClock, endReason: .recovered))
                if notifiedForCurrentOutage && !alertsPaused { effects.append(.notifyUp) }
            }
            clearOutage()
            consecutiveFailures = 0
            state = .online
            effects.append(.scheduleProbe(after: config.onlineCadence))
            return effects

        case .captivePortal:
            consecutiveFailures = 0
            var effects: [Effect] = []
            if outageStart == nil {
                effects += openOutage(
                    cause: .captivePortal, start: firstFailureAt ?? wallClock,
                    reason: "Captive portal detected", interfaceName: currentInterface,
                    wallClock: wallClock
                )
            }
            state = .captivePortal
            effects.append(.scheduleProbe(after: config.degradedCadence))
            return effects

        case let .offline(kind):
            consecutiveFailures += 1
            if firstFailureAt == nil { firstFailureAt = wallClock }

            var effects: [Effect] = [.recordFailure(kind)]

            if consecutiveFailures < config.failuresToConfirm {
                state = .suspect(failures: consecutiveFailures)
                effects.append(.scheduleProbe(after: config.degradedCadence))
                return effects
            }

            if outageStart == nil {
                effects += openOutage(
                    cause: .probeFailed, start: firstFailureAt ?? wallClock,
                    reason: nil, interfaceName: currentInterface, wallClock: wallClock
                )
            }

            let cadence = consecutiveFailures >= config.failuresBeforeBackoff
                ? config.backoffCadence
                : config.degradedCadence
            effects.append(.scheduleProbe(after: cadence))
            return effects
        }
    }

    private mutating func handleTick(now: ContinuousClock.Instant, wallClock: Date) -> [Effect] {
        guard let start = outageStart, !notifiedForCurrentOutage, !alertsPaused else { return [] }
        guard state == .down || state == .captivePortal else { return [] }

        let longEnough = wallClock.timeIntervalSince(start) >= config.notifyAfter.seconds
        let pastGrace = graceUntil.map { now >= $0 } ?? true

        if longEnough && pastGrace {
            notifiedForCurrentOutage = true
            return [.notifyDown]
        }
        return [.scheduleNotifyCheck(at: wallClock.addingTimeInterval(1))]
    }

    // MARK: Helpers

    private mutating func openOutage(
        cause: OutageCause,
        start: Date,
        reason: String?,
        interfaceName: String?,
        wallClock: Date
    ) -> [Effect] {
        outageStart = start
        notifiedForCurrentOutage = false
        state = cause == .captivePortal ? .captivePortal : .down
        return [
            .openOutage(cause: cause, start: start, reason: reason, interfaceName: interfaceName),
            .scheduleNotifyCheck(at: start.addingTimeInterval(config.notifyAfter.seconds)),
        ]
    }

    private mutating func clearOutage() {
        outageStart = nil
        firstFailureAt = nil
        notifiedForCurrentOutage = false
        pathUnsatisfiedSince = nil
    }

    private mutating func resume(now: ContinuousClock.Instant, grace: Duration) -> [Effect] {
        state = .unknown
        consecutiveFailures = 0
        clearOutage()
        graceUntil = now.advanced(by: grace)
        return [.scheduleProbe(after: .seconds(2))]
    }
}
