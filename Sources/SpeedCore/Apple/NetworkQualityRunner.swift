import Foundation

/// Runs Apple's own network quality tool as an optional second opinion.
///
/// Its value is the responsiveness figure, which captures bufferbloat that an idle ping
/// cannot see. Its results are kept in their own fields and never merged into the
/// Cloudflare columns, because they measure different servers by different methods.
public actor NetworkQualityRunner {
    /// The real binary is camelCase. The lowercase path only resolves because the boot
    /// volume is case-insensitive, and would break on a case-sensitive one.
    public static let executable = "/usr/bin/networkQuality"

    private var process: Process?

    public init() {}

    public func run(maxSeconds: Int = 15, interfaceName: String? = nil) async throws -> SpeedTestResult {
        let startedAt = Date()
        let start = ContinuousClock.now

        var arguments = ["-c", "-s", "-M", "\(maxSeconds)"]
        if let interfaceName { arguments.append(contentsOf: ["-I", interfaceName]) }

        let output = try await execute(arguments: arguments, deadline: Double(maxSeconds) + 10)
        guard let data = output.data(using: .utf8),
              let report = try? JSONDecoder().decode(NetworkQualityReport.self, from: data) else {
            throw SpeedTestError.engineFailure("could not read the output of networkQuality")
        }

        var result = SpeedTestResult(
            engine: .appleNetworkQuality,
            startedAt: startedAt,
            durationSeconds: ContinuousClock.now.seconds(since: start),
            interfaceName: report.interface_name ?? interfaceName
        )
        result.downloadMbps = report.downloadMbps
        result.uploadMbps = report.uploadMbps
        result.downloadBytes = UInt64(report.dl_bytes_transferred ?? 0)
        result.uploadBytes = UInt64(report.ul_bytes_transferred ?? 0)
        result.serverName = report.test_endpoint.map { "Apple CDN · \($0)" } ?? "Apple CDN"
        result.apple = AppleExtras(
            baseRttMs: report.base_rtt,
            responsivenessRPM: report.responsiveness,
            downloadResponsivenessRPM: report.dl_responsiveness,
            uploadResponsivenessRPM: report.ul_responsiveness,
            testEndpoint: report.test_endpoint,
            downloadFlows: report.dl_flows,
            uploadFlows: report.ul_flows
        )
        return result
    }

    public func cancel() {
        process?.terminate()
        process = nil
    }

    private func execute(arguments: [String], deadline: Double) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()

            process.terminationHandler = { _ in
                // Both pipes are drained: leaving stderr unread risks the child blocking
                // forever once its 64 KB buffer fills.
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                if resumed.claim() {
                    continuation.resume(returning: String(decoding: outputData, as: UTF8.self))
                }
            }

            do {
                try process.run()
            } catch {
                if resumed.claim() { continuation.resume(throwing: SpeedTestError.engineFailure(error.localizedDescription)) }
                return
            }

            // -M is a soft cap: a run asked to stop at 15 s takes 17 to 19. This is the
            // hard stop that guarantees the UI is never stuck waiting.
            Task {
                try? await Task.sleep(for: .seconds(deadline))
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(for: .seconds(2))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    if resumed.claim() {
                        continuation.resume(throwing: SpeedTestError.timeout(.download))
                    }
                }
            }
        }
    }
}

/// Guarantees a continuation is resumed exactly once across the termination handler
/// and the deadline task.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}
