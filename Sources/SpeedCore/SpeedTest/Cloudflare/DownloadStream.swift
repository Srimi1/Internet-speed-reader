import Foundation
import os

/// One connection per stream. A session delegate observes both received payload and
/// sent upload payload; task-scoped download delegates do not receive body callbacks.
final class DownloadStream: NSObject, URLSessionDataDelegate, SpeedTestStream, @unchecked Sendable {
    private var session: URLSession!
    private let state = OSAllocatedUnfairLock(initialState: State())

    private enum Direction { case download, upload }
    private struct Pending {
        let id: UUID
        let task: URLSessionTask
        let direction: Direction
        let requestedBytes: Int
        let progress: @Sendable (Int) -> Void
        let continuation: CheckedContinuation<TransferReceipt, Error>
        var bodyBytes: Int64 = 0
        var sentBytes: Int64 = 0
        var failure: SpeedTestError?
        var response: HTTPURLResponse?
        var networkProtocol: String?
        var cancelled = false
    }
    private struct State {
        var pending: Pending?
        var cancelledID: UUID?
        var invalidated = false
    }
    private struct ProgressUpdate {
        let callback: (@Sendable (Int) -> Void)?
        let bytes: Int
        let taskToCancel: URLSessionTask?
    }

    init(configuration: URLSessionConfiguration) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func download(bytes: Int, nonce: String, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        var request = URLRequest(url: CloudflareEndpoints.download(bytes: bytes, nonce: nonce))
        request.httpMethod = "GET"
        return try await execute(request: request, file: nil, bytes: bytes, progress: progress)
    }

    func upload(bytes: Int, file: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        var request = URLRequest(url: CloudflareEndpoints.upload)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(bytes)", forHTTPHeaderField: "Content-Length")
        return try await execute(request: request, file: file, bytes: bytes, progress: progress)
    }

    private func execute(request: URLRequest, file: URL?, bytes: Int, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionTask = if let file {
                    session.uploadTask(with: request, fromFile: file)
                } else {
                    session.dataTask(with: request)
                }
                let installed = state.withLock { state in
                    guard !state.invalidated, state.cancelledID != id else { return false }
                    precondition(state.pending == nil, "A stream runs one request at a time")
                    state.pending = Pending(
                        id: id, task: task, direction: file == nil ? .download : .upload,
                        requestedBytes: bytes, progress: progress, continuation: continuation
                    )
                    return true
                }
                if installed { task.resume() }
                else { task.cancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    private func cancel(id: UUID) {
        let pending = state.withLock { state -> Pending? in
            // Cancellation may precede continuation installation.
            state.cancelledID = id
            guard state.pending?.id == id else { return nil }
            state.pending?.cancelled = true
            return state.pending
        }
        pending?.task.cancel()
    }

    func invalidate() {
        let pending = state.withLock { state -> Pending? in
            state.invalidated = true
            state.pending?.cancelled = true
            return state.pending
        }
        pending?.task.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allowed = state.withLock { state -> Bool in
            guard var pending = state.pending, pending.task.taskIdentifier == dataTask.taskIdentifier else { return false }
            defer { state.pending = pending }
            guard let http = response as? HTTPURLResponse else {
                pending.failure = .interception("non-HTTP response")
                return false
            }
            pending.response = http
            CloudflareResponseDiagnostics.record(http,
                phase: pending.direction == .download ? "download" : "upload",
                requestedBytes: pending.requestedBytes)
            let validation = pending.direction == .download
                ? ResponseValidator.validateDownload(status: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    expectedContentLength: http.expectedContentLength, requestedBytes: pending.requestedBytes)
                : ResponseValidator.validateUpload(status: http.statusCode,
                    confirmedBytesHeader: http.value(forHTTPHeaderField: "cf-meta-upload-bytes"),
                    sentBytes: pending.requestedBytes)
            do { try validation.requireValid(); return true }
            catch { pending.failure = error as? SpeedTestError; return false }
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let update = state.withLock { state -> ProgressUpdate? in
            guard var pending = state.pending, pending.task.taskIdentifier == dataTask.taskIdentifier,
                  pending.direction == .download, !pending.cancelled, pending.failure == nil else { return nil }
            defer { state.pending = pending }
            pending.bodyBytes += Int64(data.count)
            if pending.bodyBytes > Int64(pending.requestedBytes) {
                pending.failure = .interception("download exceeded the requested byte count")
                return ProgressUpdate(callback: nil, bytes: 0, taskToCancel: pending.task)
            }
            return ProgressUpdate(callback: pending.progress, bytes: data.count, taskToCancel: nil)
        }
        update?.taskToCancel?.cancel()
        if let update { update.callback?(update.bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let update = state.withLock { state -> ProgressUpdate? in
            guard var pending = state.pending, pending.task.taskIdentifier == task.taskIdentifier,
                  pending.direction == .upload, !pending.cancelled, pending.failure == nil else { return nil }
            defer { state.pending = pending }
            guard totalBytesSent >= pending.sentBytes, totalBytesSent <= Int64(pending.requestedBytes) else {
                pending.failure = .engineFailure("Upload restarted or sent an unexpected byte count")
                return ProgressUpdate(callback: nil, bytes: 0, taskToCancel: pending.task)
            }
            let delta = totalBytesSent - pending.sentBytes
            pending.sentBytes = totalBytesSent
            return ProgressUpdate(callback: pending.progress, bytes: Int(delta), taskToCancel: nil)
        }
        update?.taskToCancel?.cancel()
        if let update, update.bytes > 0 { update.callback?(update.bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = state.withLock { state -> Pending? in
            guard state.pending?.task.taskIdentifier == task.taskIdentifier else { return nil }
            let pending = state.pending
            state.pending = nil
            return pending
        }
        guard let pending else { return }
        do {
            // Await URLSession's terminal callback before releasing run ownership. An
            // immediate continuation resume allowed a new run to overlap a cancelled one.
            if pending.cancelled { throw CancellationError() }
            if let failure = pending.failure { throw failure }
            if let error { throw error }
            guard pending.response != nil else { throw SpeedTestError.engineFailure("No speed test response") }
            if pending.direction == .download {
                try ResponseValidator.validateDownloadCompletion(
                    receivedBytes: pending.bodyBytes, requestedBytes: pending.requestedBytes
                ).requireValid()
            } else if pending.sentBytes != Int64(pending.requestedBytes) {
                throw SpeedTestError.engineFailure("Upload progress did not match the confirmed byte count")
            }
            pending.continuation.resume(returning: TransferReceipt(bytes: pending.requestedBytes, networkProtocol: pending.networkProtocol))
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        state.withLock { state in
            guard state.pending?.task.taskIdentifier == task.taskIdentifier else { return }
            state.pending?.networkProtocol = metrics.transactionMetrics.last?.networkProtocolName
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A portal or proxy must not redirect an upload body to another host.
        completionHandler(nil)
    }
}
