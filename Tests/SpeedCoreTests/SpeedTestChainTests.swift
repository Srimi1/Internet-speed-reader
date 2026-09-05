import Foundation
import os
import Testing
@testable import SpeedCore

/// A scripted engine: it records that it ran and then produces whatever the test wants.
private final class StubEngine: SpeedTestEngine, @unchecked Sendable {
    let key: SpeedTestEngineKey
    private let outcome: @Sendable () async throws -> SpeedTestResult
    private let reachedPhase: SpeedTestPhase?
    private let state = OSAllocatedUnfairLock(initialState: (ran: false, cancelled: false))

    init(
        key: SpeedTestEngineKey,
        reachedPhase: SpeedTestPhase? = nil,
        outcome: @escaping @Sendable () async throws -> SpeedTestResult
    ) {
        self.key = key
        self.reachedPhase = reachedPhase
        self.outcome = outcome
    }

    static func failing(_ key: SpeedTestEngineKey, with error: SpeedTestError, reachedPhase: SpeedTestPhase? = nil) -> StubEngine {
        StubEngine(key: key, reachedPhase: reachedPhase) { throw error }
    }

    static func succeeding(_ key: SpeedTestEngineKey, downloadMbps: Double = 100) -> StubEngine {
        StubEngine(key: key) {
            var result = SpeedTestResult(engine: key.resultEngine, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            result.downloadMbps = downloadMbps
            result.uploadMbps = downloadMbps / 2
            return result
        }
    }

    var ran: Bool { state.withLock { $0.ran } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func run(_ request: SpeedTestRequest, progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestResult {
        state.withLock { $0.ran = true }
        if let reachedPhase { progress(SpeedTestProgress(phase: reachedPhase)) }
        return try await outcome()
    }

    func cancel() async { state.withLock { $0.cancelled = true } }
}

@Suite("Speed test chain")
struct SpeedTestChainTests {
    private let request = SpeedTestRequest()

    /// The v1 failure: one host refuses and the whole test dies. The chain must move on.
    @Test("A refusal hands over to the next engine")
    func refusalTriesNext() async throws {
        let first = StubEngine.failing(.cloudflareH3, with: .refused(status: 403))
        let second = StubEngine.succeeding(.cloudflareLegacy)
        let outcome = try await SpeedTestChainRunner().run(engines: [first, second], request: request) { _ in }

        #expect(first.ran)
        #expect(second.ran)
        #expect(outcome.result.engineKey == SpeedTestEngineKey.cloudflareLegacy.rawValue)
        #expect(outcome.attempted == [.cloudflareH3, .cloudflareLegacy])
        // The refusing engine is held back so the next run does not walk into it again.
        #expect(outcome.backoffs[.cloudflareH3] == SpeedTestChainPolicy.refusalBackoff)
    }

    @Test("A rate limit backs off only the engine that returned it")
    func rateLimitBacksOffOneEngine() async throws {
        let first = StubEngine.failing(.cloudflareH3, with: .rateLimited)
        let second = StubEngine.succeeding(.cloudflareLegacy)
        let outcome = try await SpeedTestChainRunner().run(engines: [first, second], request: request) { _ in }
        #expect(outcome.backoffs[.cloudflareH3] == SpeedTestChainPolicy.rateLimitBackoff)
        #expect(outcome.backoffs[.cloudflareLegacy] == nil)
    }

    /// Backoffs matter most when everything refuses, and that path throws, so they have to
    /// travel on the error too.
    @Test("When every engine refuses the failure still carries the backoffs")
    func allRefusedReportsBackoffs() async {
        let engines = [
            StubEngine.failing(.cloudflareH3, with: .refused(status: 403)),
            StubEngine.failing(.cloudflareLegacy, with: .refused(status: 403)),
            StubEngine.failing(.apple, with: .engineFailure("tool missing")),
        ]
        do {
            _ = try await SpeedTestChainRunner().run(engines: engines, request: request) { _ in }
            Issue.record("A chain where everything fails must throw")
        } catch let failure as SpeedTestChainFailure {
            #expect(failure.attempted == [.cloudflareH3, .cloudflareLegacy, .apple])
            #expect(failure.backoffs[.cloudflareH3] == SpeedTestChainPolicy.refusalBackoff)
            #expect(failure.backoffs[.cloudflareLegacy] == SpeedTestChainPolicy.refusalBackoff)
            #expect(failure.backoffs[.apple] == nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// A finished download means the link works. Paying for another engine's full
    /// transfer would double the data cost and produce a number from a different server.
    @Test("A failure after the download phase stops the chain")
    func failureAfterDownloadStops() async {
        let first = StubEngine.failing(.cloudflareH3, with: .insufficientData, reachedPhase: .upload)
        let second = StubEngine.succeeding(.cloudflareLegacy)
        do {
            _ = try await SpeedTestChainRunner().run(engines: [first, second], request: request) { _ in }
            Issue.record("The chain must not continue after a completed download phase")
        } catch {
            #expect(!second.ran)
        }
    }

    @Test("Cancellation ends the chain instead of trying another engine")
    func cancellationStops() async {
        let first = StubEngine.failing(.cloudflareH3, with: .cancelled)
        let second = StubEngine.succeeding(.cloudflareLegacy)
        do {
            _ = try await SpeedTestChainRunner().run(engines: [first, second], request: request) { _ in }
            Issue.record("Cancellation must not fall through")
        } catch {
            #expect(!second.ran)
        }
    }

    @Test("A successful result records its engine and what it fell back from")
    func resultRecordsProvenance() async throws {
        let engines = [
            StubEngine.failing(.cloudflareH3, with: .refused(status: 403)),
            StubEngine.succeeding(.cloudflareLegacy),
        ]
        let outcome = try await SpeedTestChainRunner().run(engines: engines, request: SpeedTestRequest(trigger: "scheduled")) { _ in }
        #expect(outcome.result.fallbackFrom == [SpeedTestEngineKey.cloudflareH3.rawValue])
        #expect(outcome.result.trigger == "scheduled")
    }

    @Test("The first engine's success records no fallback")
    func firstEngineHasNoFallback() async throws {
        let outcome = try await SpeedTestChainRunner().run(
            engines: [StubEngine.succeeding(.cloudflareH3)], request: request
        ) { _ in }
        #expect(outcome.result.fallbackFrom == nil)
        #expect(outcome.attempted == [.cloudflareH3])
    }

    /// Each engine restarts at the first phase, so progress carries an attempt number:
    /// without it the display would reject every update after the first engine.
    @Test("Progress is stamped with the attempt and the engine name")
    func progressCarriesAttemptAndLabel() async throws {
        let engines = [
            StubEngine.failing(.cloudflareH3, with: .refused(status: 403), reachedPhase: .meta),
            StubEngine.succeeding(.cloudflareLegacy),
        ]
        let updates = OSAllocatedUnfairLock(initialState: [SpeedTestProgress]())
        _ = try await SpeedTestChainRunner().run(engines: engines, request: request) { progress in
            updates.withLock { $0.append(progress) }
        }
        let recorded = updates.withLock { $0 }
        #expect(recorded.contains { $0.attempt == 0 && $0.engineLabel == SpeedTestEngineKey.cloudflareH3.displayName })
        #expect(recorded.contains { $0.attempt == 1 && $0.engineLabel == SpeedTestEngineKey.cloudflareLegacy.displayName })
    }

    @Test("An empty engine list is an error, not a silent success")
    func emptyChain() async {
        do {
            _ = try await SpeedTestChainRunner().run(engines: [], request: request) { _ in }
            Issue.record("An empty chain must fail")
        } catch {
            #expect(error as? SpeedTestError != nil)
        }
    }
}

@Suite("Speed test chain policy")
struct SpeedTestChainPolicyTests {
    @Test("Refusals and rate limits hand over with the right backoff")
    func refusalsTryNext() {
        #expect(SpeedTestChainPolicy.decide(after: SpeedTestError.refused(status: 403),
                                            downloadPhaseCompleted: false, bytesTransferred: 0, isLastEngine: false)
                == .tryNext(backoff: SpeedTestChainPolicy.refusalBackoff))
        #expect(SpeedTestChainPolicy.decide(after: SpeedTestError.refused(status: 429),
                                            downloadPhaseCompleted: false, bytesTransferred: 0, isLastEngine: false)
                == .tryNext(backoff: SpeedTestChainPolicy.rateLimitBackoff))
        #expect(SpeedTestChainPolicy.decide(after: SpeedTestError.interception("portal"),
                                            downloadPhaseCompleted: false, bytesTransferred: 0, isLastEngine: false)
                == .tryNext(backoff: nil))
    }

    /// Falling through on a timeout would abandon a working provider for one whose
    /// numbers are not comparable, so only explicit refusals advance the chain.
    @Test("Timeouts and local faults stop the chain")
    func faultsStop() {
        let stopping: [any Error] = [
            SpeedTestError.timeout(.download),
            SpeedTestError.cancelled,
            SpeedTestError.offline,
            SpeedTestError.networkChanged,
            SpeedTestError.insufficientData,
            SpeedTestError.engineFailure("bad"),
            CancellationError(),
        ]
        for error in stopping {
            #expect(SpeedTestChainPolicy.decide(after: error, downloadPhaseCompleted: false,
                                                bytesTransferred: 0, isLastEngine: false) == .stop)
        }
    }

    @Test("The last engine never hands over")
    func lastEngineStops() {
        #expect(SpeedTestChainPolicy.decide(after: SpeedTestError.refused(status: 403),
                                            downloadPhaseCompleted: false, bytesTransferred: 0, isLastEngine: true) == .stop)
    }

    @Test("A chain that already moved real data stops rather than paying twice")
    func byteBudgetStops() {
        #expect(SpeedTestChainPolicy.decide(after: SpeedTestError.refused(status: 403),
                                            downloadPhaseCompleted: false,
                                            bytesTransferred: SpeedTestChainPolicy.chainByteBudget,
                                            isLastEngine: false) == .stop)
    }
}
