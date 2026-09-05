import Foundation
import os
import Testing
@testable import SpeedCore

private enum SamplerTestError: Error { case timedOut }

private func waitForSampler(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw SamplerTestError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// Sleep advances only when the test requests it; cancellation still wakes a paused loop.
private final class SamplerClock: TimeSource, Sendable {
    private final class Sleeper: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, any Error>?
            var finished = false
            var cancelled = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        var isPending: Bool { state.withLock { !$0.finished } }

        func install(_ continuation: CheckedContinuation<Void, any Error>) {
            let cancelled = state.withLock {
                if $0.cancelled { return true }
                $0.continuation = continuation
                return false
            }
            if cancelled { continuation.resume(throwing: CancellationError()) }
        }

        func finish(cancelled: Bool) {
            let continuation = state.withLock {
                guard !$0.finished else { return nil as CheckedContinuation<Void, any Error>? }
                $0.finished = true
                $0.cancelled = cancelled
                let continuation = $0.continuation
                $0.continuation = nil
                return continuation
            }
            if cancelled { continuation?.resume(throwing: CancellationError()) }
            else { continuation?.resume() }
        }
    }

    private struct State {
        var offset = Duration.zero
        var sleepers: [Sleeper] = []
        var requestedDurations: [Duration] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let origin = ContinuousClock.now

    func now() -> ContinuousClock.Instant { origin.advanced(by: state.withLock { $0.offset }) }
    func wallClock() -> Date { Date(timeIntervalSince1970: 1_700_000_000 + state.withLock { $0.offset.seconds }) }
    var pendingSleeps: Int { state.withLock { $0.sleepers.filter(\.isPending).count } }
    var requestedDurations: [Duration] { state.withLock { $0.requestedDurations } }

    func sleep(for duration: Duration, tolerance: Duration?) async throws {
        let sleeper = Sleeper()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleeper.install(continuation)
                state.withLock {
                    $0.sleepers.append(sleeper)
                    $0.requestedDurations.append(duration)
                }
            }
        } onCancel: {
            sleeper.finish(cancelled: true)
        }
    }

    func advance(by seconds: Double) {
        let sleepers = state.withLock {
            $0.offset += .seconds(seconds)
            let sleepers = $0.sleepers
            $0.sleepers.removeAll()
            return sleepers
        }
        sleepers.forEach { $0.finish(cancelled: false) }
    }
}

private final class SamplerCounters: CounterSource, Sendable {
    private struct State {
        var current: IFCounters? = IFCounters(rx: 0, tx: 0)
        var readIndices: [Int] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var readCount: Int { state.withLock { $0.readIndices.count } }
    var lastIndex: Int? { state.withLock { $0.readIndices.last } }
    func set(_ counters: IFCounters?) { state.withLock { $0.current = counters } }
    func counters(forInterfaceIndex index: Int) -> IFCounters? {
        state.withLock { $0.readIndices.append(index); return $0.current }
    }
    func allCounters() -> [Int: IFCounters] { [:] }
}

private final class SamplerUpdates: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [LiveThroughputUpdate]())
    func record(_ update: LiveThroughputUpdate) { storage.withLock { $0.append(update) } }
    var values: [LiveThroughputUpdate] { storage.withLock { $0 } }
    var samples: [ThroughputSample] {
        values.compactMap { if case let .sample(sample) = $0 { return sample }; return nil }
    }
}

private struct SamplerHarness {
    let clock = SamplerClock()
    let counters = SamplerCounters()
    let updates = SamplerUpdates()
    let monitor: LiveThroughputMonitor
    private var collector: Task<Void, Never>?

    init() { monitor = LiveThroughputMonitor(counters: counters, time: clock) }

    mutating func start(cadence: Double = 1) async throws {
        let stream = await monitor.updates()
        collector = Task { [updates] in
            for await update in stream { updates.record(update) }
        }
        await monitor.setInterface(name: "en0", index: 11)
        await monitor.setCadence(.seconds(cadence))
        await monitor.start()
        try await waitForSampler { [clock, counters] in counters.readCount >= 1 && clock.pendingSleeps == 1 }
    }

    func tick(after seconds: Double = 1, counters reading: IFCounters?) async throws {
        counters.set(reading)
        let count = counters.readCount
        clock.advance(by: seconds)
        try await waitForSampler { [clock, counters] in counters.readCount > count && clock.pendingSleeps == 1 }
    }

    func stop() async { collector?.cancel(); await monitor.stop() }
}

@Suite("Live throughput monitor", .timeLimit(.minutes(1)))
struct LiveThroughputMonitorTests {
    @Test("Closed-panel monitoring emits correct rates at every power cadence", arguments: [1.0, 2.0, 5.0])
    func coalescedCadences(cadence: Double) async throws {
        var harness = SamplerHarness()
        try await harness.start(cadence: cadence)
        let elapsed = cadence + 0.25
        try await harness.tick(after: elapsed, counters: IFCounters(rx: UInt64(1_250_000 * elapsed), tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        let sample = try #require(harness.updates.samples.first)
        #expect(abs(sample.downMbps - 10) < 0.0001)
        #expect(sample.elapsedSeconds == elapsed)
        await harness.stop()
    }

    @Test("Missing counters become unavailable and recover without spanning the failure")
    func missingCountersRecover() async throws {
        var harness = SamplerHarness()
        try await harness.start()
        try await harness.tick(counters: IFCounters(rx: 1_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        try await harness.tick(counters: nil)
        try await waitForSampler { harness.updates.values.contains(.unavailable(.counterUnavailable)) }
        try await harness.tick(counters: IFCounters(rx: 500_000_000, tx: 0))
        #expect(harness.updates.samples.count == 1)
        try await harness.tick(counters: IFCounters(rx: 501_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 2 }
        #expect(harness.updates.samples.last?.downMbps == 10)
        await harness.stop()
    }

    @Test("A long unexpected scheduling gap reports stale then resumes normally")
    func longGapRecovers() async throws {
        var harness = SamplerHarness()
        try await harness.start()
        try await harness.tick(after: 60, counters: IFCounters(rx: 500_000_000, tx: 0))
        try await waitForSampler { harness.updates.values.contains(.unavailable(.stale)) }
        #expect(harness.updates.samples.isEmpty)
        try await harness.tick(counters: IFCounters(rx: 501_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        #expect(harness.updates.samples.last?.downMbps == 10)
        await harness.stop()
    }

    @Test("Repeated start is idempotent and wake does not include sleeping traffic")
    func pauseAndResume() async throws {
        var harness = SamplerHarness()
        try await harness.start()
        await harness.monitor.start()
        #expect(harness.clock.pendingSleeps == 1)
        #expect(harness.counters.readCount == 1)
        await harness.monitor.pause()
        let readCount = harness.counters.readCount
        harness.clock.advance(by: 600)
        #expect(harness.counters.readCount == readCount)
        harness.counters.set(IFCounters(rx: 500_000_000, tx: 0))
        await harness.monitor.start()
        try await waitForSampler { harness.counters.readCount == readCount + 1 && harness.clock.pendingSleeps == 1 }
        try await harness.tick(counters: IFCounters(rx: 501_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        #expect(harness.updates.samples.last?.downMbps == 10)
        await harness.stop()
    }

    @Test("Interface loss publishes unavailable and a new interface starts a fresh baseline")
    func interfaceReplacement() async throws {
        var harness = SamplerHarness()
        try await harness.start()
        try await harness.tick(counters: IFCounters(rx: 1_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        await harness.monitor.clearInterface()
        try await waitForSampler { harness.updates.values.contains(.unavailable(.noInterface)) }
        await harness.monitor.setInterface(name: "en5", index: 14)
        try await harness.tick(counters: IFCounters(rx: 900_000_000, tx: 0))
        try await harness.tick(counters: IFCounters(rx: 901_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 2 }
        #expect(harness.updates.samples.last?.interfaceName == "en5")
        #expect(harness.updates.samples.last?.downMbps == 10)
        #expect(harness.counters.lastIndex == 14)
        await harness.stop()
    }

    @Test("Changing cadence replaces the old sleep immediately and keeps one loop")
    func cadenceChangeWhileRunning() async throws {
        var harness = SamplerHarness()
        try await harness.start(cadence: 5)
        await harness.monitor.setCadence(.seconds(1))
        try await waitForSampler { harness.clock.requestedDurations.count >= 2 && harness.clock.pendingSleeps == 1 }
        #expect(harness.clock.requestedDurations.last == .seconds(1))
        try await harness.tick(counters: IFCounters(rx: 1_250_000, tx: 0))
        try await waitForSampler { harness.updates.samples.count == 1 }
        #expect(harness.updates.samples.last?.downMbps == 10)
        #expect(harness.clock.pendingSleeps == 1)
        await harness.stop()
    }
}
