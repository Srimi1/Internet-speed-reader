import Foundation

/// Adapts the macOS networkQuality tool to the chain.
///
/// Last in every chain: it selects its own endpoint, which can be much further away than
/// a nearby CDN edge, so its numbers are a second opinion rather than a substitute.
public struct AppleEngine: SpeedTestEngine {
    public let key: SpeedTestEngineKey = .apple
    private let runner: NetworkQualityRunner

    public init(runner: NetworkQualityRunner = NetworkQualityRunner()) {
        self.runner = runner
    }

    public func run(
        _ request: SpeedTestRequest,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestResult {
        // The tool reports nothing until it exits, so the phase is announced once and the
        // gauge simply shows that a measurement is under way.
        progress(SpeedTestProgress(phase: .download, engineLabel: SpeedTestEngineKey.apple.displayName))
        var result = try await runner.run(maxSeconds: request.appleMaxSeconds, interfaceName: request.interfaceName)
        result.endpointHost = result.apple?.testEndpoint
        return result
    }

    public func cancel() async {
        // Joins process termination and pipe cleanup before returning.
        await runner.cancel()
    }
}
