import Foundation

/// Injectable at the transport boundary: engine tests never need a network or app host.
protocol CloudflareTransport: Sendable {
    func data(for request: URLRequest, timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse)
    func makeStream(timeoutSeconds: Double) -> any SpeedTestStream
}

protocol SpeedTestStream: Sendable {
    func download(bytes: Int, nonce: String, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt
    func upload(bytes: Int, file: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt
    func invalidate()
}

struct TransferReceipt: Sendable {
    let bytes: Int
    let networkProtocol: String?
}

final class URLSessionCloudflareTransport: CloudflareTransport, @unchecked Sendable {
    let configuration: @Sendable (Double) -> URLSessionConfiguration
    private let endpoints: CloudflareEndpoints
    private let controlSession: URLSession

    init(
        endpoints: CloudflareEndpoints = .h3,
        configuration: @escaping @Sendable (Double) -> URLSessionConfiguration = CloudflareSpeedTest.makeSessionConfiguration
    ) {
        self.endpoints = endpoints
        self.configuration = configuration
        // Latency samples must reuse a connection; a fresh session per sample would
        // charge DNS/TCP/TLS setup on every request and could never measure warm RTT.
        self.controlSession = URLSession(configuration: configuration(5))
    }

    deinit { controlSession.invalidateAndCancel() }

    func data(for request: URLRequest, timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeoutSeconds
        let (data, response) = try await controlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpeedTestError.interception("non-HTTP response")
        }
        return (data, http)
    }

    func makeStream(timeoutSeconds: Double) -> any SpeedTestStream {
        DownloadStream(configuration: configuration(timeoutSeconds), endpoints: endpoints)
    }
}
