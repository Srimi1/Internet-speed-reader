import Foundation

/// Why a chain gave up, and what it learned on the way.
///
/// Backoffs travel on the failure as well as on success: the case that most needs them is
/// the one where every engine refuses, and that case throws.
public struct SpeedTestChainFailure: Error, Sendable {
    public let attempted: [SpeedTestEngineKey]
    public let backoffs: [SpeedTestEngineKey: Duration]
    public let underlying: any Error

    public init(attempted: [SpeedTestEngineKey], backoffs: [SpeedTestEngineKey: Duration], underlying: any Error) {
        self.attempted = attempted
        self.backoffs = backoffs
        self.underlying = underlying
    }
}

public struct ChainOutcome: Sendable {
    public let result: SpeedTestResult
    public let attempted: [SpeedTestEngineKey]
    public let backoffs: [SpeedTestEngineKey: Duration]
}

/// Whether a failed engine should hand over to the next one.
///
/// Pure, so every rule is testable without a network. The decision is deliberately
/// conservative: falling through costs the user another full transfer, and the last link
/// in the chain measures against a different provider whose numbers are not comparable.
public enum SpeedTestChainPolicy {
    /// A refusal blocks that engine for long enough that the next press does not walk
    /// straight back into it.
    public static let refusalBackoff = Duration.seconds(5 * 60)
    /// A rate limit is the provider asking for a longer pause.
    public static let rateLimitBackoff = Duration.seconds(15 * 60)
    /// Once this much validated payload has moved, the link works; a later failure is not
    /// a reason to pay for another engine's full download phase.
    public static let chainByteBudget: UInt64 = 64 * 1024 * 1024

    public enum Decision: Equatable, Sendable {
        case tryNext(backoff: Duration?)
        case stop
    }

    public static func decide(
        after error: any Error,
        downloadPhaseCompleted: Bool,
        bytesTransferred: UInt64,
        isLastEngine: Bool
    ) -> Decision {
        if isLastEngine { return .stop }
        // A finished download phase means this engine works. Whatever failed afterwards
        // is not something a different server can answer, and re-running would double the
        // data cost for a worse number.
        if downloadPhaseCompleted { return .stop }
        if bytesTransferred >= chainByteBudget { return .stop }

        guard let failure = error as? SpeedTestError else {
            // Cancellation, deadlines and anything unrecognised end the chain: only an
            // explicit refusal is evidence that a different endpoint would do better.
            return .stop
        }

        switch failure {
        case .refused(let status):
            return .tryNext(backoff: status == 429 ? rateLimitBackoff : refusalBackoff)
        case .rateLimited:
            return .tryNext(backoff: rateLimitBackoff)
        case .interception:
            // Something on the path answered for the server. Another host may not be
            // intercepted, and nothing was measured, so trying costs little.
            return .tryNext(backoff: nil)
        case .cancelled, .offline, .networkChanged, .insufficientData, .timeout, .engineFailure:
            return .stop
        }
    }
}

/// Runs engines in order until one produces a result.
public actor SpeedTestChainRunner {
    private let time: any TimeSource
    private var active: (any SpeedTestEngine)?

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
    }

    public func run(
        engines: [any SpeedTestEngine],
        request: SpeedTestRequest,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> ChainOutcome {
        guard !engines.isEmpty else { throw SpeedTestError.engineFailure("No speed test engine is available.") }

        var attempted: [SpeedTestEngineKey] = []
        var backoffs: [SpeedTestEngineKey: Duration] = [:]
        var lastError: any Error = SpeedTestError.insufficientData

        for (index, engine) in engines.enumerated() {
            try Task.checkCancellation()
            let isLast = index == engines.count - 1
            attempted.append(engine.key)
            active = engine

            // Each engine restarts at the first phase, so progress carries the attempt
            // number: without it the display would reject everything after the first
            // engine as an out-of-order update.
            let tracker = PhaseTracker()
            let attemptProgress: @Sendable (SpeedTestProgress) -> Void = { update in
                tracker.record(update.phase)
                var stamped = update
                stamped.attempt = index
                stamped.engineLabel = engine.key.displayName
                progress(stamped)
            }
            attemptProgress(SpeedTestProgress(phase: .meta))

            do {
                var result = try await engine.run(request, progress: attemptProgress)
                active = nil
                result.engineKey = engine.key.rawValue
                result.trigger = request.trigger
                let earlier = attempted.dropLast().map(\.rawValue)
                if !earlier.isEmpty { result.fallbackFrom = Array(earlier) }
                Log.speedTest.info("chain engine=\(engine.key.rawValue, privacy: .public) result=ok attempt=\(index)")
                return ChainOutcome(result: result, attempted: attempted, backoffs: backoffs)
            } catch {
                active = nil
                lastError = error
                let decision = SpeedTestChainPolicy.decide(
                    after: error,
                    downloadPhaseCompleted: tracker.reachedUpload,
                    bytesTransferred: tracker.bytes,
                    isLastEngine: isLast
                )
                if case let .tryNext(backoff) = decision {
                    if let backoff { backoffs[engine.key] = backoff }
                    Log.speedTest.error("chain engine=\(engine.key.rawValue, privacy: .public) outcome=refused next=yes")
                    continue
                }
                Log.speedTest.error("chain engine=\(engine.key.rawValue, privacy: .public) outcome=stop")
                throw SpeedTestChainFailure(attempted: attempted, backoffs: backoffs, underlying: error)
            }
        }
        throw SpeedTestChainFailure(attempted: attempted, backoffs: backoffs, underlying: lastError)
    }

    /// Cancels whichever engine is running and waits for its cleanup.
    public func cancel() async {
        await active?.cancel()
    }
}

/// Tracks how far one engine got, so the policy can tell a refusal from a late failure.
private final class PhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0
    private(set) var bytes: UInt64 = 0

    func record(_ phase: SpeedTestPhase) {
        lock.lock()
        defer { lock.unlock() }
        highest = max(highest, phase.rank)
    }

    var reachedUpload: Bool {
        lock.lock()
        defer { lock.unlock() }
        return highest >= SpeedTestPhase.uploadProbe.rank
    }
}
