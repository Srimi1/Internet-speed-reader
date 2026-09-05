import Foundation
import Testing
@testable import SpeedCore

@Suite("Speed test run ownership")
struct SpeedTestRunGateTests {
    @Test func cancellationKeepsOwnershipUntilCleanupAndRejectsLateCallbacks() throws {
        var gate = SpeedTestRunGate()
        let now = ContinuousClock.now
        let firstID = gate.begin(at: now, cloudflare: true)
        let first = try #require(firstID)
        #expect(gate.acceptsProgress(from: first))
        let stopped = gate.requestStop()
        #expect(stopped)
        let stoppedTwice = gate.requestStop()
        #expect(!stoppedTwice)
        #expect(!gate.acceptsProgress(from: first))
        let overlapping = gate.begin(at: now.advanced(by: .seconds(60)), cloudflare: false)
        #expect(overlapping == nil)
        let finished = gate.finish(first, at: now)
        #expect(finished)
        #expect(!gate.canStart(at: now.advanced(by: .seconds(29)), cloudflare: true))
        let secondID = gate.begin(at: now.advanced(by: .seconds(30)), cloudflare: true)
        let second = try #require(secondID)
        #expect(!gate.acceptsProgress(from: first))
        let staleFinished = gate.finish(first, at: now.advanced(by: .seconds(40)))
        #expect(!staleFinished)
        #expect(gate.acceptsProgress(from: second))
    }

    @Test func rateLimitExpiresWithoutRestartAndDoesNotBlockAppleAfterSpacing() throws {
        var gate = SpeedTestRunGate()
        let now = ContinuousClock.now
        let firstID = gate.begin(at: now, cloudflare: true)
        let first = try #require(firstID)
        let finished = gate.finish(first, at: now, rateLimited: true)
        #expect(finished)
        #expect(!gate.canStart(at: now.advanced(by: .seconds(30)), cloudflare: true))
        #expect(gate.canStart(at: now.advanced(by: .seconds(30)), cloudflare: false))
        #expect(gate.remainingWait(at: now.advanced(by: .seconds(899)), cloudflare: true) == 1)
        #expect(gate.canStart(at: now.advanced(by: .seconds(900)), cloudflare: true))
        #expect(!gate.isRateLimited(at: now.advanced(by: .seconds(900))))
    }
}
