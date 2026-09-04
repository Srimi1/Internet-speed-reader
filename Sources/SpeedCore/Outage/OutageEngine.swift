import Foundation

/// What the engine tells the outside world.
public enum OutageEvent: Sendable, Equatable {
    case stateChanged(ConnectivityStateMachine.State)
    case notifyDown(OutageRecord)
    case notifyUp(OutageRecord)
    case ledgerChanged
}

/// Drives ConnectivityStateMachine with real probes, timers and the ledger.
/// All decisions live in the machine; this actor only supplies time and I/O.
public actor OutageEngine {
    private var machine: ConnectivityStateMachine
    private let prober: any Prober
    private let ledger: OutageLedger
    private let time: any TimeSource

    private var probeTask: Task<Void, Never>?
    private var notifyTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var continuation: AsyncStream<OutageEvent>.Continuation?
    private var lastInterfaceName: String?

    public init(
        prober: any Prober,
        ledger: OutageLedger,
        time: any TimeSource = SystemTimeSource(),
        config: ConnectivityStateMachine.Config = .init()
    ) {
        self.prober = prober
        self.ledger = ledger
        self.time = time
        self.machine = ConnectivityStateMachine(config: config)
    }

    public func events() -> AsyncStream<OutageEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public var state: ConnectivityStateMachine.State { machine.state }

    public func start() async {
        await ledger.load()
        startHeartbeat()
        await dispatch(.launched)
    }

    public func stop() {
        probeTask?.cancel(); probeTask = nil
        notifyTask?.cancel(); notifyTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        continuation?.finish()
    }

    /// Closes an open outage cleanly when the app quits, so it is never mistaken
    /// for a crash orphan on next launch.
    public func shutdown() async {
        await ledger.close(at: time.wallClock(), reason: .quit)
        stop()
    }

    public func setAlertsPaused(_ paused: Bool) {
        machine.setAlertsPaused(paused)
    }

    // MARK: External events

    public func pathChanged(_ snapshot: PathSnapshot) async {
        let interfaceName = snapshot.activeInterface?.name
        let changed = interfaceName != lastInterfaceName
        lastInterfaceName = interfaceName
        await dispatch(.path(
            status: snapshot.status,
            reason: snapshot.unsatisfiedReason,
            interfaceName: interfaceName,
            interfaceChanged: changed
        ))
    }

    public func willSleep() async { await dispatch(.willSleep) }
    public func didWake() async { await dispatch(.didWake) }
    public func speedTestStarted() async { await dispatch(.speedTestStarted) }
    public func speedTestFinished(success: Bool) async { await dispatch(.speedTestFinished(success: success)) }
    public func checkNow() async { await runProbe() }

    public func outages() async -> [OutageRecord] { await ledger.all() }
    public func clearOutages() async { await ledger.clear(); continuation?.yield(.ledgerChanged) }

    // MARK: Core loop

    private func dispatch(_ event: ConnectivityStateMachine.Event) async {
        let before = machine.state
        let effects = machine.handle(event, now: time.now(), wallClock: time.wallClock())
        await apply(effects)
        if machine.state != before {
            continuation?.yield(.stateChanged(machine.state))
        }
    }

    private func apply(_ effects: [ConnectivityStateMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case let .scheduleProbe(after):
                scheduleProbe(after: after)

            case let .openOutage(cause, start, reason, interfaceName):
                await ledger.open(OutageRecord(
                    start: start,
                    confirmedAt: time.wallClock(),
                    interfaceName: interfaceName,
                    cause: cause,
                    unsatisfiedReason: reason
                ))
                continuation?.yield(.ledgerChanged)

            case let .recordFailure(kind):
                await ledger.recordFailure(kind)

            case let .closeOutage(date, reason):
                if let closed = await ledger.close(at: date, reason: reason) {
                    continuation?.yield(.ledgerChanged)
                    lastClosedOutage = closed
                } else {
                    continuation?.yield(.ledgerChanged)
                    lastClosedOutage = nil
                }

            case .notifyDown:
                await ledger.markNotified()
                if let open = await ledger.openRecord() {
                    continuation?.yield(.notifyDown(open))
                }

            case .notifyUp:
                if let closed = lastClosedOutage {
                    continuation?.yield(.notifyUp(closed))
                }

            case let .scheduleNotifyCheck(at):
                scheduleNotifyCheck(at: at)
            }
        }
    }

    private var lastClosedOutage: OutageRecord?

    private func scheduleProbe(after delay: Duration) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            guard let self else { return }
            if delay > .zero {
                do { try await self.time.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self.runProbe()
        }
    }

    private func runProbe() async {
        // Never probe while suspended: that is what keeps Power Nap dark wakes and
        // speed tests from generating phantom outages.
        if case .suspended = machine.state { return }
        let outcome = await prober.probe()
        await dispatch(.probe(outcome))
    }

    private func scheduleNotifyCheck(at date: Date) {
        notifyTask?.cancel()
        let delay = max(0.5, date.timeIntervalSince(time.wallClock()))
        notifyTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.time.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self.dispatch(.tick)
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.ledger.heartbeat(now: self.time.wallClock())
                do { try await self.time.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}
