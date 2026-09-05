import Foundation
import Testing
@testable import SpeedCore

@Suite("Speed test run gate")
struct SpeedTestRunGateTests {
    private let start = ContinuousClock.now
    private let auto: [SpeedTestEngineKey] = [.cloudflareH3, .cloudflareLegacy, .apple]

    @Test("A fresh gate can start and hands out one run at a time")
    func singleOwner() {
        var gate = SpeedTestRunGate()
        #expect(gate.canStart(at: start, engines: auto))
        let first = gate.begin(at: start, engines: auto)
        #expect(first != nil)
        // A second run cannot begin while the first still owns the gate.
        #expect(gate.begin(at: start, engines: auto) == nil)
        #expect(!gate.canStart(at: start, engines: auto))
    }

    @Test("Progress and ownership are rejected for anything but the active run")
    func ownership() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        let stale = UUID()
        #expect(gate.acceptsProgress(from: id))
        #expect(!gate.acceptsProgress(from: stale))
        #expect(gate.owns(id))
        #expect(!gate.owns(stale))
    }

    /// Stop is a visible state that lasts until the engine's cleanup returns; late
    /// progress from the run being stopped must not move the display.
    @Test("Stopping rejects further progress but keeps ownership")
    func stopping() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        let stopped = gate.requestStop()
        #expect(stopped)
        #expect(gate.isStopping)
        #expect(!gate.acceptsProgress(from: id))
        #expect(gate.owns(id))
        // A second stop request changes nothing.
        let again = gate.requestStop()
        #expect(!again)
    }

    @Test("Finishing starts a shared thirty second spacing")
    func spacing() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        let finished = gate.finish(id, at: start)
        #expect(finished)
        #expect(!gate.canStart(at: start, engines: auto))
        #expect(!gate.canStart(at: start.advanced(by: .seconds(29)), engines: auto))
        #expect(gate.canStart(at: start.advanced(by: .seconds(30)), engines: auto))
    }

    @Test("A stale run cannot finish the gate on behalf of the active one")
    func staleFinishIsIgnored() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        let finishedStale = gate.finish(UUID(), at: start)
        #expect(!finishedStale)
        #expect(gate.owns(id))
    }

    /// The point of per-engine backoffs: one provider refusing must not silence the
    /// others, and must not be retried immediately.
    @Test("A backoff blocks only the engine that earned it")
    func backoffIsPerEngine() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        _ = gate.finish(id, at: start, backoffs: [.cloudflareH3: .seconds(300)])

        let later = start.advanced(by: .seconds(60))
        #expect(gate.isBlocked(.cloudflareH3, at: later))
        #expect(!gate.isBlocked(.cloudflareLegacy, at: later))
        #expect(!gate.isBlocked(.apple, at: later))
        #expect(gate.blockedEngines(at: later) == [.cloudflareH3])

        // The chain skips the blocked engine and runs the rest.
        #expect(gate.availableEngines(at: later, from: auto) == [.cloudflareLegacy, .apple])
        #expect(gate.canStart(at: later, engines: auto))
    }

    @Test("A backoff expires on its own")
    func backoffExpires() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        _ = gate.finish(id, at: start, backoffs: [.cloudflareH3: .seconds(300)])
        #expect(!gate.isBlocked(.cloudflareH3, at: start.advanced(by: .seconds(301))))
        #expect(gate.availableEngines(at: start.advanced(by: .seconds(301)), from: auto) == auto)
    }

    @Test("When every engine is blocked the wait reports the soonest one")
    func allBlocked() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        _ = gate.finish(id, at: start, backoffs: [
            .cloudflareH3: .seconds(300), .cloudflareLegacy: .seconds(900), .apple: .seconds(600),
        ])
        let later = start.advanced(by: .seconds(60))
        #expect(gate.availableEngines(at: later, from: auto).isEmpty)
        #expect(!gate.canStart(at: later, engines: auto))
        // 300 s backoff, 60 s elapsed: the first engine returns in 240 s.
        #expect(abs(gate.remainingWait(at: later, engines: auto) - 240) < 0.001)
    }

    @Test("Apple stays available while Cloudflare is rate limited")
    func appleSurvivesCloudflareBackoff() {
        var gate = SpeedTestRunGate()
        let id = gate.begin(at: start, engines: auto)!
        _ = gate.finish(id, at: start, backoffs: [
            .cloudflareH3: .seconds(900), .cloudflareLegacy: .seconds(900),
        ])
        let later = start.advanced(by: .seconds(31))
        #expect(gate.canStart(at: later, engines: [.apple]))
        #expect(gate.availableEngines(at: later, from: auto) == [.apple])
    }
}
