import Foundation
import os

/// Counts upload bytes as they are handed to the socket.
final class UploadStreamDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let ledger: ByteLedger
    private let lastReported = OSAllocatedUnfairLock(initialState: Int64(0))

    init(ledger: ByteLedger) { self.ledger = ledger }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        // Report the delta so restarts or retries cannot double count.
        let delta = lastReported.withLock { previous -> Int64 in
            let change = totalBytesSent - previous
            previous = totalBytesSent
            return change
        }
        if delta > 0 { ledger.add(Int(delta)) }
    }
}
