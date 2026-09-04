import Foundation
import Observation
import SpeedCore

/// Owns the running test and everything the panel needs to draw it.
@Observable
@MainActor
final class SpeedTestController {
    enum RunState: Equatable {
        case idle
        case running(SpeedTestPhase)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    var state: RunState = .idle
    var phase: SpeedTestPhase = .idle
    var liveMbps: Double = 0
    var fraction: Double = 0
    var latestResult: SpeedTestResult?
    var history: [SpeedTestResult] = []
    /// Set while a rate limit backoff is in effect.
    var blockedUntil: Date?

    private let engine = CloudflareSpeedTest()
    private let apple = NetworkQualityRunner()
    private var task: Task<Void, Never>?
    fileprivate(set) var store: AtomicJSONStore<SpeedTestResult>?
    private var lastRunFinished: Date?

    /// Tests are spaced so a double click, or an impatient retry, cannot hammer the
    /// public endpoints.
    static let minimumSpacing: TimeInterval = 30

    var onStateChange: ((Bool) -> Void)?

    init() {
        if let url = try? AppPaths.applicationSupportDirectory().appendingPathComponent("speedtests.json") {
            let store = AtomicJSONStore<SpeedTestResult>(url: url, cap: 200)
            self.store = store
            history = store.load().sorted { $0.startedAt > $1.startedAt }
            latestResult = history.first
        }
    }

    var canStart: Bool {
        guard !state.isRunning else { return false }
        if let blockedUntil, blockedUntil > Date() { return false }
        if let lastRunFinished, Date().timeIntervalSince(lastRunFinished) < Self.minimumSpacing { return false }
        return true
    }

    var startBlockedReason: String? {
        if let blockedUntil, blockedUntil > Date() {
            return "Cloudflare is rate limiting. Try the Apple deep test."
        }
        if let lastRunFinished {
            let wait = Self.minimumSpacing - Date().timeIntervalSince(lastRunFinished)
            if wait > 0 { return "Wait \(Int(wait.rounded()))s before testing again" }
        }
        return nil
    }

    func start(interfaceName: String?, options: SpeedTestOptions = SpeedTestOptions()) {
        guard canStart else { return }
        onStateChange?(true)
        state = .running(.meta)
        phase = .meta
        liveMbps = 0
        fraction = 0

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.run(options: options, interfaceName: interfaceName) { progress in
                    Task { @MainActor [weak self] in
                        self?.apply(progress)
                    }
                }
                self.finish(with: result)
            } catch is CancellationError {
                self.state = .idle
                self.phase = .idle
                self.onStateChange?(false)
            } catch {
                self.fail(error)
            }
        }
    }

    func startAppleDeepTest(interfaceName: String?) {
        guard !state.isRunning else { return }
        onStateChange?(true)
        state = .running(.download)
        phase = .download
        liveMbps = 0
        fraction = 0

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await apple.run(interfaceName: interfaceName)
                self.finish(with: result)
            } catch {
                self.fail(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        Task { await apple.cancel() }
        task = nil
        state = .idle
        phase = .idle
        onStateChange?(false)
    }

    private func apply(_ progress: SpeedTestProgress) {
        phase = progress.phase
        state = .running(progress.phase)
        if progress.instantaneousMbps > 0 { liveMbps = progress.instantaneousMbps }
        fraction = progress.fraction
    }

    private func finish(with result: SpeedTestResult) {
        latestResult = result
        history.insert(result, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        try? store?.save(history.reversed())
        state = .idle
        phase = .idle
        liveMbps = 0
        lastRunFinished = Date()
        onStateChange?(false)
    }

    private func fail(_ error: Error) {
        let message: String
        switch error {
        case SpeedTestError.interception(let reason):
            message = "Test blocked: \(reason)"
        case SpeedTestError.rateLimited:
            blockedUntil = Date().addingTimeInterval(15 * 60)
            message = "Cloudflare is rate limiting. Try the Apple deep test."
        case SpeedTestError.insufficientData:
            message = "Not enough data to report a reliable number"
        case SpeedTestError.offline:
            message = "No internet connection"
        default:
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        state = .failed(message)
        phase = .idle
        onStateChange?(false)
    }
}

extension SpeedTestController {
    func clearHistory() {
        history.removeAll()
        latestResult = nil
        try? store?.save([])
    }
}
