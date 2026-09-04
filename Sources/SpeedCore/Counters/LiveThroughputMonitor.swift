import Foundation

/// Samples interface counters on a cadence and publishes throughput samples.
///
/// Owns its baseline, and drops that baseline whenever it cannot trust the delta:
/// interface change, wake from sleep, counter reset, or a gap long enough that the
/// process was clearly napped. Callers get only trustworthy samples.
public actor LiveThroughputMonitor {
    public enum Cadence: Sendable {
        case seconds(Double)

        var duration: Duration { .seconds(interval) }

        var interval: Double {
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
    private var continuation: AsyncStream<ThroughputSample>.Continuation?

    public init(counters: CounterSource = SysctlCounterReader(), time: any TimeSource = SystemTimeSource()) {
        self.counters = counters
        self.time = time
    }

    public func samples() -> AsyncStream<ThroughputSample> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    public func setInterface(name: String, index: Int) {
        guard interfaceIndex != index else { return }
        interfaceIndex = index
        interfaceName = name
        resetBaseline()
        Log.live.info("live meter bound to \(name, privacy: .public) (index \(index))")
    }

    public func clearInterface() {
        interfaceIndex = nil
        interfaceName = ""
        resetBaseline()
    }

    public func setCadence(_ cadence: Cadence) {
        guard cadence.interval != self.cadence.interval else { return }
        self.cadence = cadence
        resetBaseline()
    }

    public func setDuringTest(_ value: Bool) { duringTest = value }

    /// Drops the baseline so the next tick starts fresh. Call on wake, interface change,
    /// and whenever the meter resumes, or the next delta spans the whole gap.
    public func resetBaseline() { baseline = nil }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = await self.cadence.duration
                do {
                    try await self.time.sleep(for: interval, tolerance: .milliseconds(250))
                } catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        resetBaseline()
    }

    public func pause() {
        stop()
    }

    private func tick() {
        guard let index = interfaceIndex,
              let current = counters.counters(forInterfaceIndex: index) else {
            return
        }
        let now = time.now()

        guard let previous = baseline else {
            baseline = (current, now)
            return
        }

        let elapsed = now.seconds(since: previous.at)
        switch calculator.evaluate(previous: previous.counters, current: current, elapsedSeconds: elapsed) {
        case .tooSoon:
            return
        case let .rebaseline(reason):
            Log.live.debug("rebaselining live meter: \(reason.rawValue, privacy: .public)")
            baseline = (current, now)
        case let .rate(down, up):
            baseline = (current, now)
            continuation?.yield(
                ThroughputSample(
                    downMbps: down,
                    upMbps: up,
                    interfaceName: interfaceName,
                    at: now,
                    duringTest: duringTest
                )
            )
        }
    }
}
