import Foundation
import Observation
import SpeedCore

/// Owns one test through transport cleanup, and publishes only callbacks from that run.
///
/// A run is a chain: engines are tried in order until one produces a validated result, so
/// a provider refusing a request no longer ends the attempt.
@Observable
@MainActor
final class SpeedTestController {
    enum RunState: Equatable {
        case idle
        case running(SpeedTestPhase)
        case stopping
        case failed(String)

        var isRunning: Bool {
            switch self { case .running, .stopping: return true; default: return false }
        }
    }

    enum Completion {
        case succeeded
        case failed
        case cancelled
        case interrupted
    }

    enum RunEvent {
        case started
        case finished(Completion)
    }

    var state: RunState = .idle
    var phase: SpeedTestPhase = .idle
    var liveMbps: Double = 0
    var fraction: Double = 0
    /// Which engine is being tried right now, so a fallback is visible.
    var engineLabel: String?
    var latestResult: SpeedTestResult?
    var history: [SpeedTestResult] = []
    var onRunEvent: ((RunEvent) async -> Void)?

    private let engines: [SpeedTestEngineKey: any SpeedTestEngine]
    private let chain = SpeedTestChainRunner()
    private let time: any TimeSource
    private var gate = SpeedTestRunGate()
    private var observedNow: ContinuousClock.Instant
    private var task: Task<Void, Never>?
    private var interruptionReason: String?
    /// A scheduled run must not leave an error banner behind.
    private var silentFailure = false
    private var attempt = 0
    fileprivate(set) var store: AtomicJSONStore<SpeedTestResult>?

    init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        observedNow = time.now()
        engines = [
            .cloudflareH3: CloudflareEngine(endpoints: .h3, time: time),
            .cloudflareLegacy: CloudflareEngine(endpoints: .legacy, time: time),
            .apple: AppleEngine(),
        ]
        if let url = try? AppPaths.applicationSupportDirectory().appendingPathComponent("speedtests.json") {
            let store = AtomicJSONStore<SpeedTestResult>(url: url, cap: 200)
            self.store = store
            history = store.load().sorted { $0.startedAt > $1.startedAt }
            latestResult = history.first
        }
    }

    /// Called by the always-running UI refresh loop, so cooldown expiry is observable
    /// even with the popover closed. Wall-clock corrections cannot skip the cooldown.
    func refreshTime() { observedNow = time.now() }

    func canStart(choice: SpeedTestEngineChoice) -> Bool {
        gate.canStart(at: observedNow, engines: choice.engineKeys)
    }

    var canStartApple: Bool { gate.canStart(at: observedNow, engines: [.apple]) }

    func startBlockedReason(choice: SpeedTestEngineChoice) -> String? {
        if gate.isStopping { return "Stopping the test…" }
        let spacing = gate.spacingWait(at: observedNow)
        if spacing > 0 { return "Wait \(Int(ceil(spacing)))s before testing again" }
        let blocked = gate.availableEngines(at: observedNow, from: choice.engineKeys).isEmpty
        guard blocked else { return nil }
        let wait = gate.remainingWait(at: observedNow, engines: choice.engineKeys)
        let minutes = max(1, Int(ceil(wait / 60)))
        let names = choice.engineKeys.map(\.displayName).joined(separator: ", ")
        return "\(names) refused the last test. Retry in \(minutes) min."
    }

    func start(choice: SpeedTestEngineChoice, request: SpeedTestRequest, silentFailure: Bool = false) {
        refreshTime()
        // Engines still inside a refusal backoff are skipped rather than re-tried, so a
        // provider that just said no is not asked again on the next press.
        var keys = gate.availableEngines(at: observedNow, from: choice.engineKeys)
        if keys.isEmpty { keys = choice.engineKeys }
        guard let id = gate.begin(at: observedNow, engines: keys) else { return }
        let ordered = keys.compactMap { engines[$0] }
        guard !ordered.isEmpty else { _ = gate.finish(id, at: time.now()); return }

        interruptionReason = nil
        self.silentFailure = silentFailure
        attempt = 0
        state = .running(.meta)
        phase = .meta
        liveMbps = 0
        fraction = 0
        engineLabel = ordered.first?.key.displayName
        let chain = self.chain
        task = Task { [weak self] in
            guard let self else { return }
            await self.onRunEvent?(.started)
            do {
                try Task.checkCancellation()
                let outcome = try await chain.run(engines: ordered, request: request) { progress in
                    Task { @MainActor [weak self] in self?.apply(progress, runID: id) }
                }
                try Task.checkCancellation()
                await self.complete(id, result: outcome.result, error: nil, backoffs: outcome.backoffs)
            } catch let failure as SpeedTestChainFailure {
                await self.complete(id, result: nil, error: failure.underlying, backoffs: failure.backoffs,
                                    attempted: failure.attempted)
            } catch {
                await self.complete(id, result: nil, error: error, backoffs: [:])
            }
        }
    }

    func cancel(reason: String? = nil) {
        guard gate.requestStop() else { return }
        interruptionReason = reason
        state = .stopping
        liveMbps = 0
        task?.cancel()
        // Both engines implement cancellation that joins transport/subprocess cleanup.
        // Keep ownership and the Stop state until the task actually returns.
        let chain = self.chain
        Task { await chain.cancel() }
    }

    func cancelAndWait() async {
        let running = task
        cancel()
        await running?.value
    }

    private func apply(_ progress: SpeedTestProgress, runID: UUID) {
        guard gate.acceptsProgress(from: runID) else { return }
        // Each engine restarts at the first phase, so a later attempt always wins even
        // though its phase rank is lower. Within one attempt, progress only moves forward.
        guard (progress.attempt, progress.phase.rank) >= (attempt, phase.rank) else { return }
        attempt = progress.attempt
        phase = progress.phase
        state = .running(progress.phase)
        engineLabel = progress.engineLabel ?? engineLabel
        liveMbps = progress.instantaneousMbps.isFinite ? max(0, progress.instantaneousMbps) : 0
        fraction = progress.fraction.isFinite ? min(1, max(0, progress.fraction)) : 0
    }

    private func complete(
        _ id: UUID,
        result: SpeedTestResult?,
        error: Error?,
        backoffs: [SpeedTestEngineKey: Duration],
        attempted: [SpeedTestEngineKey] = []
    ) async {
        guard gate.owns(id) else { return }
        let stopped = gate.isStopping || error is CancellationError || (error as? SpeedTestError) == .cancelled
        let outcome: Completion
        var nextState: RunState = .idle
        if stopped {
            if let reason = interruptionReason {
                nextState = .failed(reason)
                outcome = .interrupted
            } else {
                outcome = .cancelled
            }
        } else if let result {
            latestResult = result
            history.insert(result, at: 0)
            history = Array(history.prefix(200))
            do { try store?.save(history.reversed()) }
            catch { Log.speedTest.error("could not save test history: \(error.localizedDescription, privacy: .public)") }
            outcome = .succeeded
        } else {
            nextState = silentFailure ? .idle : .failed(message(for: error ?? SpeedTestError.insufficientData, attempted: attempted))
            outcome = .failed
        }

        // Remain busy while connectivity/lifecycle state is restored. A new test must
        // not race an old run's delayed 'finished' event.
        await onRunEvent?(.finished(outcome))
        // Backoffs are applied whether the chain succeeded or gave up: the case that most
        // needs them is every engine refusing, which throws.
        guard gate.finish(id, at: time.now(), backoffs: backoffs) else { return }
        state = nextState
        phase = .idle
        engineLabel = nil
        liveMbps = 0
        fraction = 0
        attempt = 0
        interruptionReason = nil
        silentFailure = false
        task = nil
        refreshTime()
    }

    private func message(for error: Error, attempted: [SpeedTestEngineKey]) -> String {
        let detail: String
        switch error {
        case SpeedTestError.interception(let reason): detail = "Test blocked: \(reason)"
        case SpeedTestError.refused(let status): detail = "The speed test server refused the request (HTTP \(status))."
        case SpeedTestError.rateLimited: detail = "The speed test server is rate limiting. Try again shortly."
        case SpeedTestError.insufficientData: detail = "Not enough validated data to report a reliable speed."
        case SpeedTestError.offline: detail = "No internet connection."
        case SpeedTestError.networkChanged: detail = "Network changed. Run a new test on this connection."
        case SpeedTestError.timeout: detail = "The test timed out. Check your connection and try again."
        case SpeedTestError.engineFailure(let reason): detail = reason
        default: detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        guard attempted.count > 1 else { return detail }
        let names = attempted.map(\.displayName).joined(separator: ", ")
        return "\(detail) Tried: \(names)."
    }

    func clearHistory() {
        history.removeAll()
        latestResult = nil
        try? store?.save([])
    }
}
