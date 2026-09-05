import Foundation
import Observation
import SpeedCore

/// Owns one test through transport cleanup, and publishes only callbacks from that run.
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
    var latestResult: SpeedTestResult?
    var history: [SpeedTestResult] = []
    var onRunEvent: ((RunEvent) async -> Void)?

    private let engine = CloudflareSpeedTest()
    private let apple = NetworkQualityRunner()
    private let time: any TimeSource
    private var gate = SpeedTestRunGate()
    private var observedNow: ContinuousClock.Instant
    private var task: Task<Void, Never>?
    private var interruptionReason: String?
    fileprivate(set) var store: AtomicJSONStore<SpeedTestResult>?

    init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        observedNow = time.now()
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

    var canStart: Bool { gate.canStart(at: observedNow, cloudflare: true) }
    var canStartApple: Bool { gate.canStart(at: observedNow, cloudflare: false) }
    var startBlockedReason: String? {
        if gate.isStopping { return "Stopping the test…" }
        if gate.isRateLimited(at: observedNow) {
            let wait = Int(ceil(gate.remainingWait(at: observedNow, cloudflare: true) / 60))
            return "Cloudflare is rate limiting. Retry in \(wait) min, or use Apple Deep Test."
        }
        let wait = gate.remainingWait(at: observedNow, cloudflare: true)
        return wait > 0 ? "Wait \(Int(ceil(wait)))s before testing again" : nil
    }

    func start(interfaceName: String?, options: SpeedTestOptions = SpeedTestOptions()) {
        startRun(interfaceName: interfaceName, options: options, appleMaxSeconds: nil)
    }

    func startAppleDeepTest(interfaceName: String?, maxSeconds: Int = 15) {
        startRun(interfaceName: interfaceName, options: SpeedTestOptions(), appleMaxSeconds: maxSeconds)
    }

    private func startRun(interfaceName: String?, options: SpeedTestOptions, appleMaxSeconds: Int?) {
        refreshTime()
        guard let id = gate.begin(at: observedNow, cloudflare: appleMaxSeconds == nil) else { return }
        interruptionReason = nil
        state = .running(.meta)
        phase = .meta
        liveMbps = 0
        fraction = 0
        task = Task { [weak self] in
            guard let self else { return }
            await self.onRunEvent?(.started)
            do {
                try Task.checkCancellation()
                let result: SpeedTestResult
                if let maxSeconds = appleMaxSeconds {
                    self.phase = .download
                    self.state = .running(.download)
                    result = try await self.apple.run(maxSeconds: maxSeconds, interfaceName: interfaceName)
                } else {
                    result = try await self.engine.run(options: options, interfaceName: interfaceName) { progress in
                        Task { @MainActor [weak self] in self?.apply(progress, runID: id) }
                    }
                }
                try Task.checkCancellation()
                await self.complete(id, result: result, error: nil)
            } catch {
                await self.complete(id, result: nil, error: error)
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
    }

    func cancelAndWait() async {
        let running = task
        cancel()
        await running?.value
    }

    private func apply(_ progress: SpeedTestProgress, runID: UUID) {
        guard gate.acceptsProgress(from: runID) else { return }
        // Delegate callbacks hop to MainActor; an earlier phase's queued progress
        // must not move the gauge backwards after the next phase has started.
        let order: [SpeedTestPhase] = [.idle, .meta, .latency, .downloadProbe, .download, .uploadProbe, .upload, .finishing]
        guard (order.firstIndex(of: progress.phase) ?? 0) >= (order.firstIndex(of: phase) ?? 0) else { return }
        phase = progress.phase
        state = .running(progress.phase)
        liveMbps = progress.instantaneousMbps.isFinite ? max(0, progress.instantaneousMbps) : 0
        fraction = progress.fraction.isFinite ? min(1, max(0, progress.fraction)) : 0
    }

    private func complete(_ id: UUID, result: SpeedTestResult?, error: Error?) async {
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
            nextState = .failed(message(for: error ?? SpeedTestError.insufficientData))
            outcome = .failed
        }

        // Remain busy while connectivity/lifecycle state is restored. A new test must
        // not race an old run's delayed 'finished' event.
        await onRunEvent?(.finished(outcome))
        guard gate.finish(id, at: time.now(), rateLimited: !stopped && (error as? SpeedTestError) == .rateLimited) else { return }
        state = nextState
        phase = .idle
        liveMbps = 0
        fraction = 0
        interruptionReason = nil
        task = nil
        refreshTime()
    }

    private func message(for error: Error) -> String {
        switch error {
        case SpeedTestError.interception(let reason): return "Test blocked: \(reason)"
        case SpeedTestError.rateLimited: return "Cloudflare is rate limiting. Try Apple Deep Test."
        case SpeedTestError.insufficientData: return "Not enough validated data to report a reliable speed."
        case SpeedTestError.offline: return "No internet connection."
        case SpeedTestError.networkChanged: return "Network changed. Run a new test on this connection."
        case SpeedTestError.timeout: return "The test timed out. Check your connection and try again."
        case SpeedTestError.engineFailure(let reason): return reason
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearHistory() {
        history.removeAll()
        latestResult = nil
        try? store?.save([])
    }
}
