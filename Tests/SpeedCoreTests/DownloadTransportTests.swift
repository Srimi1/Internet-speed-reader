import Foundation
import os
import Testing
@testable import SpeedCore

/// Each URLProtocol instance chooses its script from a request header, so parallel
/// tests never share mutable routing state or contact a public endpoint.
private final class MeasurementURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Measurement-Test") ?? "valid"
        if scenario == "silent" { return }
        if scenario == "no-response" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let status = scenario == "rate-limit" ? 429 : scenario == "forbidden" ? 403 : 200
        let headers = ["Content-Type": scenario == "portal" ? "text/html" : "application/octet-stream", "Content-Length": "1024"]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 200 || scenario == "portal" { client?.urlProtocolDidFinishLoading(self); return }
        client?.urlProtocol(self, didLoad: Data(count: scenario == "truncated" ? 100 : scenario == "oversized" ? 2048 : 1024))
        if scenario == "reset" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

@Suite("Validated download transport", .timeLimit(.minutes(1)))
struct DownloadTransportTests {
    private func stream(_ scenario: String) -> DownloadStream {
        let configuration = CloudflareSpeedTest.makeSessionConfiguration(timeoutSeconds: 2)
        configuration.protocolClasses = [MeasurementURLProtocol.self]
        configuration.httpAdditionalHeaders?["X-Measurement-Test"] = scenario
        return DownloadStream(configuration: configuration)
    }

    @Test("Exact body completion is required after valid headers", arguments: ["valid", "truncated", "oversized", "no-response", "reset", "portal", "rate-limit", "forbidden"])
    func completion(_ scenario: String) async throws {
        let stream = stream(scenario)
        defer { stream.invalidate() }
        let bytes = ByteLedger()
        do {
            let receipt = try await stream.download(bytes: 1024, nonce: UUID().uuidString) { bytes.add($0) }
            #expect(scenario == "valid")
            #expect(receipt.bytes == 1024)
            #expect(bytes.bytes == 1024)
        } catch {
            #expect(scenario != "valid")
            if scenario == "rate-limit" { #expect(error as? SpeedTestError == .rateLimited) }
            if scenario == "forbidden" {
                #expect(error as? SpeedTestError == .engineFailure("Speed test server returned HTTP 403"))
            }
        }
    }

    @Test("Cancellation resumes a silent request without waiting for resource timeout")
    func cancelsSilentRequest() async throws {
        let stream = stream("silent")
        defer { stream.invalidate() }
        let task = Task { try await stream.download(bytes: 1024, nonce: "cancel", progress: { _ in }) }
        for _ in 0..<20 { await Task.yield() }
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled request must throw") }
        catch { #expect(error is CancellationError) }
        #expect(ContinuousClock.now.seconds(since: start) < 1)
    }
}
