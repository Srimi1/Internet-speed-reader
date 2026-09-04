import Foundation
import os
import Testing
@testable import SpeedCore

/// Prober whose answers are scripted, so an outage can be simulated without a network.
private final class ScriptedProber: Prober, Sendable {
    private struct Script { var outcomes: [ProbeOutcome]; var last: ProbeOutcome; var calls: Int }
    private let state: OSAllocatedUnfairLock<Script>

    init(_ outcomes: [ProbeOutcome]) {
        state = OSAllocatedUnfairLock(
            initialState: Script(
                outcomes: outcomes,
                last: outcomes.last ?? .offline(kind: .timedOut),
                calls: 0
            )
        )
    }

    /// Repeats the final scripted answer once exhausted: a real network does not
    /// spontaneously change state just because the script ended.
    func probe() async -> ProbeOutcome {
        state.withLock { script in
            script.calls += 1
            guard !script.outcomes.isEmpty else { return script.last }
            let next = script.outcomes.removeFirst()
            script.last = next
            return next
        }
    }

    func setOutcomes(_ new: [ProbeOutcome]) {
        state.withLock {
            $0.outcomes = new
            if let last = new.last { $0.last = last }
        }
    }

    var callCount: Int { state.withLock { $0.calls } }
}

/// Fast-forwarding clock: sleeps return immediately but advance the reported time,
/// so a ten-second rule can be exercised in milliseconds.
private final class FastClock: TimeSource, Sendable {
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
    private let origin = ContinuousClock.now
    private let wallOrigin = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> ContinuousClock.Instant {
        origin.advanced(by: offset.withLock { $0 })
    }

    func wallClock() -> Date {
        wallOrigin.addingTimeInterval(offset.withLock { $0 }.seconds)
    }

    func sleep(for duration: Duration, tolerance: Duration?) async throws {
        offset.withLock { $0 += duration }
        await Task.yield()
    }
}

/// Sendable flag box so a collector task can report back without data races.
private final class Flags: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (down: false, up: false))
    var sawDown: Bool { state.withLock { $0.down } }
    var sawUp: Bool { state.withLock { $0.up } }
    func markDown() { state.withLock { $0.down = true } }
    func markUp() { state.withLock { $0.up = true } }
}

private func tempLedger() -> OutageLedger {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("isr-engine-\(UUID().uuidString)")
        .appendingPathComponent("outages.json")
    return OutageLedger(store: AtomicJSONStore(url: url), heartbeatStore: MemoryHeartbeatStore())
}

@Suite("Outage engine", .timeLimit(.minutes(1)))
struct OutageEngineTests {
    @Test("A real outage is detected, logged and announced, then closed on recovery")
    func fullOutageCycle() async throws {
        let prober = ScriptedProber([
            .online(rttMs: 20, viaFallback: false),
            .offline(kind: .timedOut),
            .offline(kind: .timedOut),
        ])
        let ledger = tempLedger()
        let engine = OutageEngine(prober: prober, ledger: ledger, time: FastClock())

        let flags = Flags()
        let events = await engine.events()
        let collector = Task {
            for await event in events {
                if case .notifyDown = event { flags.markDown() }
                if case .notifyUp = event { flags.markUp(); break }
            }
        }

        await engine.start()

        // Let the scripted failures land and the notify threshold elapse.
        try await Task.sleep(for: .milliseconds(400))
        #expect(flags.sawDown, "an outage past the notify threshold should announce itself")

        let openRecords = await engine.outages().filter(\.isOpen)
        #expect(openRecords.count == 1)
        #expect(openRecords.first?.cause == .probeFailed)

        prober.setOutcomes([.online(rttMs: 18, viaFallback: false)])
        await engine.checkNow()
        try await Task.sleep(for: .milliseconds(200))

        #expect(flags.sawUp, "recovery after an announced outage should announce the restore")
        let all = await engine.outages()
        #expect(all.allSatisfy { !$0.isOpen })
        collector.cancel()
        await engine.stop()
    }

    @Test("A captive portal is reported as a portal rather than a plain outage")
    func captivePortalDetected() async throws {
        let prober = ScriptedProber([.captivePortal, .captivePortal])
        let engine = OutageEngine(prober: prober, ledger: tempLedger(), time: FastClock())

        await engine.start()
        try await Task.sleep(for: .milliseconds(200))

        let state = await engine.state
        #expect(state == .captivePortal)
        let records = await engine.outages()
        #expect(records.first?.cause == .captivePortal)
        await engine.stop()
    }

    @Test("No probes run while suspended, which is what makes sleep safe")
    func noProbesWhileSuspended() async throws {
        let prober = ScriptedProber([.online(rttMs: 10, viaFallback: false)])
        let engine = OutageEngine(prober: prober, ledger: tempLedger(), time: FastClock())

        await engine.start()
        try await Task.sleep(for: .milliseconds(100))
        await engine.willSleep()

        let before = prober.callCount
        await engine.checkNow()
        try await Task.sleep(for: .milliseconds(100))
        #expect(prober.callCount == before, "a suspended engine must not probe")
        await engine.stop()
    }
}
