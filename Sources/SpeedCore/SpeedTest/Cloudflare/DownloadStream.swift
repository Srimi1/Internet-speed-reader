import Foundation
import os

/// A single download stream: its own session, its own connection, streaming byte counts.
///
/// This uses a SESSION-level delegate rather than the per-task delegate accepted by
/// `URLSession.data(from:delegate:)`. That convenience API accumulates the body itself
/// and never calls `didReceive data`, so a task delegate counts zero bytes while the
/// transfer visibly succeeds. Verified the hard way: the first live run reported a
/// perfect upload and a download of 0.0 Mbps.
public final class DownloadStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let ledger: ByteLedger
    private var session: URLSession!
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var validation: ResponseValidation = .valid
        var networkProtocol: String?
        var continuation: CheckedContinuation<ResponseValidation, Never>?
        var requestedBytes = 0
    }

    public init(ledger: ByteLedger, timeoutSeconds: Double) {
        self.ledger = ledger
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(
            configuration: CloudflareSpeedTest.makeSessionConfiguration(timeoutSeconds: timeoutSeconds),
            delegate: self,
            delegateQueue: queue
        )
    }

    public var networkProtocolName: String? { state.withLock { $0.networkProtocol } }

    public func invalidate() { session.invalidateAndCancel() }

    /// Fetches one chunk, counting bytes into the shared ledger as they arrive.
    public func fetch(url: URL, requestedBytes: Int) async -> ResponseValidation {
        state.withLock {
            $0.validation = .valid
            $0.requestedBytes = requestedBytes
        }

        return await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            session.dataTask(with: request).resume()
        }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            state.withLock { $0.validation = .intercepted(reason: "non-HTTP response") }
            completionHandler(.cancel)
            return
        }
        let requested = state.withLock { $0.requestedBytes }
        let outcome = ResponseValidator.validateDownload(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            expectedContentLength: http.expectedContentLength,
            requestedBytes: requested
        )
        state.withLock { $0.validation = outcome }
        completionHandler(outcome == .valid ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        ledger.add(data.count)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = state.withLock { state -> CheckedContinuation<ResponseValidation, Never>? in
            let pending = state.continuation
            state.continuation = nil
            return pending
        }
        continuation?.resume(returning: state.withLock { $0.validation })
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        if let name = metrics.transactionMetrics.last?.networkProtocolName {
            state.withLock { $0.networkProtocol = name }
        }
    }
}
