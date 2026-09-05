import Foundation
import os

/// Runs Apple's network quality tool as an optional second opinion. Results remain
/// separate from Cloudflare because the engines use different servers and methods.
public actor NetworkQualityRunner {
    public static let executable = "/usr/bin/networkQuality"

    private let time: any TimeSource
    private let processFactory: @Sendable () -> any NetworkQualityProcess
    private var active: (id: UUID, task: Task<SpeedTestResult, Error>)?

    public init(time: any TimeSource = SystemTimeSource()) {
        self.time = time
        self.processFactory = { SystemNetworkQualityProcess() }
    }

    public init(
        time: any TimeSource = SystemTimeSource(),
        processFactory: @escaping @Sendable () -> any NetworkQualityProcess
    ) {
        self.time = time
        self.processFactory = processFactory
    }

    public func run(maxSeconds: Int = 15, interfaceName: String? = nil) async throws -> SpeedTestResult {
        guard active == nil else {
            throw SpeedTestError.engineFailure("An Apple Deep Test is still running or stopping.")
        }
        guard maxSeconds > 0, maxSeconds < Int.max - 10 else {
            throw SpeedTestError.engineFailure("Apple Deep Test duration must be positive.")
        }
        let id = UUID()
        let process = processFactory()
        let time = self.time
        let task = Task {
            try await Self.measure(process: process, time: time, maxSeconds: maxSeconds, interfaceName: interfaceName)
        }
        active = (id, task)
        defer { if active?.id == id { active = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Returns only after termination and pipe cleanup, so a new run cannot overlap
    /// a cancelled child. Cancellation alone used to let partial JSON become success.
    public func cancel() async {
        guard let task = active?.task else { return }
        task.cancel()
        _ = await task.result
    }

    private static func measure(
        process: any NetworkQualityProcess, time: any TimeSource,
        maxSeconds: Int, interfaceName: String?
    ) async throws -> SpeedTestResult {
        if Task.isCancelled { throw SpeedTestError.cancelled }
        let startedAt = time.wallClock()
        let start = time.now()
        var arguments = ["-c", "-s", "-M", "\(maxSeconds)"]
        if let interfaceName { arguments.append(contentsOf: ["-I", interfaceName]) }
        do { try process.start(arguments: arguments) }
        catch { throw SpeedTestError.engineFailure("Could not start Apple Deep Test: \(error.localizedDescription)") }

        let stop = NetworkQualityStopControl(process: process, time: time)
        let output = try await withTaskCancellationHandler {
            // Covers cancellation between the initial check and handler registration.
            if Task.isCancelled { stop.request(.cancelled) }
            let deadline = Task {
                do {
                    try await time.sleep(for: .seconds(maxSeconds + 10), tolerance: .zero)
                    stop.request(.timeout(.download))
                } catch { /* Completion cancels the obsolete deadline. */ }
            }
            defer { deadline.cancel() }
            let output = await process.waitForExit()
            // Mark completion before cancelling the deadline: a late timer cannot
            // turn an already-completed process into a timeout (or the reverse).
            let reason = await stop.finished()
            if let reason { throw reason }
            if Task.isCancelled { throw SpeedTestError.cancelled }
            return output
        } onCancel: {
            stop.request(.cancelled)
        }

        guard output.exitedNormally, output.terminationStatus == 0 else {
            throw SpeedTestError.engineFailure("Apple Deep Test exited unsuccessfully (status \(output.terminationStatus)).")
        }
        guard !output.outputTruncated else {
            throw SpeedTestError.engineFailure("Apple Deep Test returned incomplete or excessive output.")
        }
        let report: NetworkQualityReport
        do { report = try JSONDecoder().decode(NetworkQualityReport.self, from: output.stdout) }
        catch { throw SpeedTestError.engineFailure("Could not read the output of Apple Deep Test.") }
        let measured = try report.validatedMeasurements()
        var result = SpeedTestResult(
            engine: .appleNetworkQuality,
            startedAt: startedAt,
            durationSeconds: time.now().seconds(since: start),
            interfaceName: report.interface_name ?? interfaceName
        )
        result.methodologyVersion = 2
        result.downloadQuality = "good"
        result.uploadQuality = "good"
        result.downloadMbps = measured.downloadMbps
        result.uploadMbps = measured.uploadMbps
        result.downloadBytes = measured.downloadBytes
        result.uploadBytes = measured.uploadBytes
        result.serverName = report.test_endpoint.map { "Apple CDN · \($0)" } ?? "Apple CDN"
        result.apple = AppleExtras(
            baseRttMs: Self.usableMetric(report.base_rtt),
            responsivenessRPM: Self.usableMetric(report.responsiveness),
            downloadResponsivenessRPM: Self.usableMetric(report.dl_responsiveness),
            uploadResponsivenessRPM: Self.usableMetric(report.ul_responsiveness),
            testEndpoint: report.test_endpoint,
            downloadFlows: report.dl_flows.flatMap { $0 >= 0 ? $0 : nil },
            uploadFlows: report.ul_flows.flatMap { $0 >= 0 ? $0 : nil }
        )
        if Task.isCancelled { throw SpeedTestError.cancelled }
        return result
    }

    private static func usableMetric(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// The first stop reason wins even if terminate immediately produces valid-looking
/// JSON. This synchronous gate is also callable from task cancellation handlers.
private final class NetworkQualityStopControl: Sendable {
    private struct State {
        var reason: SpeedTestError?
        var finished = false
        var cleanup: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let process: any NetworkQualityProcess
    private let time: any TimeSource

    init(process: any NetworkQualityProcess, time: any TimeSource) {
        self.process = process
        self.time = time
    }

    func request(_ reason: SpeedTestError) {
        state.withLock { state in
            guard !state.finished, state.reason == nil else { return }
            state.reason = reason
            process.terminate()
            let process = self.process
            let time = self.time
            // An unstructured cleanup task must survive cancellation of the run.
            state.cleanup = Task.detached {
                do { try await time.sleep(for: .seconds(2), tolerance: .zero) }
                catch { return }
                if process.isRunning { process.forceKill() }
            }
        }
    }

    func finished() async -> SpeedTestError? {
        let (reason, cleanup) = state.withLock { state in
            state.finished = true
            return (state.reason, state.cleanup)
        }
        cleanup?.cancel()
        if let cleanup { await cleanup.value }
        return reason
    }
}
