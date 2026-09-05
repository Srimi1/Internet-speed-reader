import Foundation

/// Adapts the Cloudflare measurement engine to the chain, bound to one host.
public struct CloudflareEngine: SpeedTestEngine {
    public let key: SpeedTestEngineKey
    private let engine: CloudflareSpeedTest

    public init(endpoints: CloudflareEndpoints, time: any TimeSource = SystemTimeSource(), fixtures: UploadFixture? = nil) {
        self.key = endpoints.key
        self.engine = CloudflareSpeedTest(time: time, fixtures: fixtures, endpoints: endpoints)
    }

    init(key: SpeedTestEngineKey, engine: CloudflareSpeedTest) {
        self.key = key
        self.engine = engine
    }

    public func run(
        _ request: SpeedTestRequest,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestResult {
        try await engine.run(options: request.cloudflareOptions, interfaceName: request.interfaceName, progress: progress)
    }

    /// The transfer streams already join URLSession's terminal callback before they
    /// return, so cancelling the surrounding task is enough here.
    public func cancel() async {}
}
