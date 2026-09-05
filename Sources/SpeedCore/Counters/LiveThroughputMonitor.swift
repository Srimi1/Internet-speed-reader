import Foundation

public enum LiveThroughputUnavailableReason: Sendable, Equatable {
    case starting
    case noInterface
    case counterUnavailable
    case paused
    case stale
}

public enum LiveThroughputUpdate: Sendable, Equatable {
    case sample(ThroughputSample)
    case unavailable(LiveThroughputUnavailableReason)
}

/// Samples interface counters on a cadence and publishes throughput samples.
///
/// Owns its baseline, and drops that baseline whenever it cannot trust the delta:
/// interface change, wake from sleep, counter reset, or a gap long enough that the
/// process was clearly napped. Callers get only trustworthy samples.
public actor LiveThroughputMonitor {
    public enum Cadence: Sendable, Equatable {
        case seconds(Double)

        var duration: Duration { .seconds(interval) }

        public var interval: Double {
            switch self { case let .seconds(value): return value }
        }
    }

    private let counters: CounterSource
    private let time: any TimeSource
    private let calculator = ThroughputCalculator()

    private var baseline: (counters: IFCounters, at: ContinuousClock.Instant)?
    private var interfaceIndex: Int?
    private var interfaceName: String = ""
    private var cadence: Cadence = .seconds(1)
    private var duringTest = false
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var sampleContinuations: [UUID: AsyncStream<ThroughputSample>.Continuation] = [:]
    private var updateContinuations: [UUID: AsyncStream<LiveThroughputUpdate>.Continuation] = [:]
    private var latestUpdate: LiveThroughputUpdate = .unavailable(.paused)

    public init(counters: CounterSource = SysctlCounterReader(), time: any TimeSource = SystemTimeSource()) {
        self.counters = counters
        self.time = time
    }

    public func samples() -> AsyncStream<ThroughputSample> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            sampleContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id: id) }
            }
        }
    }

    /// A missing reading is different from measured zero traffic. Bounded buffering
    /// prevents the menu bar from replaying old rates after its consumer is delayed.
    public func updates() -> AsyncStream<LiveThroughputUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            updateContinuations[id] = continuation
            continuation.yield(latestUpdate)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id: id) }
            }
        }
    }

    private func removeSubscriber(id: UUID) {
        sampleContinuations.removeValue(forKey: id)
        updateContinuations.removeValue(forKey: id)
        if sampleContinuations.isEmpty, updateContinuations.isEmpty { stop() }
    }

    private func publish(_ update: LiveThroughputUpdate) {
        guard update != latestUpdate else { return }
        latestUpdate = update
        for continuation in updateContinuations.values { continuation.yield(update) }
        if case let .sample(sample) = update {
            for continuation in sampleContinuations.values { continuation.yield(sample) }
        }
    }

    public func setInterface(name: String, index: Int) {
        guard interfaceIndex != index || interfaceName != name else { return }
        interfaceIndex = index
        interfaceName = name
        resetBaseline()
        Log.live.info("live meter bound to \(name, privacy: .public) (index \(index))")
    }

    public func clearInterface() {
        interfaceIndex = nil
        interfaceName = ""
        baseline = nil
        publish(.unavailable(.noInterface))
    }

    public func setCadence(_ cadence: Cadence) {
        guard cadence.interval.isFinite, cadence.interval >= ThroughputCalculator.minimumIntervalSeconds else { return }
        guard cadence.interval != self.cadence.interval else { return }
        let wasRunning = task != nil
        task?.cancel()
        task = nil
        runID = nil
        self.cadence = cadence
        resetBaseline()
        // Apply a new setting now, rather than waiting out the old five-second sleep.
        if wasRunning { start() }
    }

    public func setDuringTest(_ value: Bool) { duringTest = value }

    /// Drops the baseline so the next tick starts fresh. Call on wake, interface change,
    /// and whenever the meter resumes, or the next delta spans the whole gap.
    public func resetBaseline() {
        baseline = nil
        publish(.unavailable(interfaceIndex == nil ? .noInterface : .starting))
    }

    public func start() {
        guard task == nil else { return }
        resetBaseline()
        let id = UUID()
        runID = id
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(runID: id)
                let interval = await self.cadence.duration
                do {
                    try await self.time.sleep(for: interval, tolerance: .milliseconds(250))
                } catch { break }
            }
            await self?.loopEnded(id: id)
        }
    }

    private func loopEnded(id: UUID) {
        // Cancellation of an old loop must never clear its already-running replacement.
        guard runID == id else { return }
        task = nil
        runID = nil
        baseline = nil
        publish(.unavailable(.stale))
    }

    public func stop() {
        task?.cancel()
        task = nil
        runID = nil
        baseline = nil
        publish(.unavailable(.paused))
    }

    public func pause() {
        stop()
    }

    private func tick(runID id: UUID) {
        guard runID == id else { return }
        guard let index = interfaceIndex else {
            baseline = nil
            publish(.unavailable(.noInterface))
            return
        }
        guard let current = counters.counters(forInterfaceIndex: index) else {
            // Missing counters formerly left the last nonzero number on screen forever.
            baseline = nil
            publish(.unavailable(.counterUnavailable))
            return
        }
        let now = time.now()

        guard let previous = baseline else {
            baseline = (current, now)
            publish(.unavailable(.starting))
            return
        }

        let elapsed = now.seconds(since: previous.at)
        switch calculator.evaluate(
            previous: previous.counters,
            current: current,
            elapsedSeconds: elapsed,
            expectedIntervalSeconds: cadence.interval
        ) {
        case .tooSoon:
            return
        case let .rebaseline(reason):
            Log.live.debug("rebaselining live meter: \(reason.rawValue, privacy: .public)")
            baseline = (current, now)
            publish(.unavailable(.stale))
        case let .rate(down, up):
            baseline = (current, now)
            publish(.sample(
                ThroughputSample(
                    downMbps: down,
                    upMbps: up,
                    interfaceName: interfaceName,
                    at: now,
                    duringTest: duringTest,
                    uploadActivityMbps: ThroughputCalculator.uploadActivityMbps(
                        previous: previous.counters,
                        current: current,
                        elapsedSeconds: elapsed
                    ),
                    downloadActivityMbps: ThroughputCalculator.downloadActivityMbps(
                        previous: previous.counters,
                        current: current,
                        elapsedSeconds: elapsed
                    ),
                    elapsedSeconds: elapsed
                )
            ))
        }
    }
}
