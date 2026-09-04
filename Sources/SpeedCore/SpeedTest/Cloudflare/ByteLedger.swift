import Foundation
import os

/// One shared byte counter for every stream in a phase.
///
/// This is the single most important design decision in the engine. Throughput is the
/// SUM of all streams sampled on ONE clock, not an average or percentile of per-request
/// rates: with six parallel streams each sees roughly a sixth of the link, so averaging
/// per-request rates under-reports by about six times. Counting into one ledger also
/// means a request cancelled at the phase deadline still contributes everything it
/// delivered, rather than being thrown away.
public final class ByteLedger: Sendable {
    private let total = OSAllocatedUnfairLock(initialState: UInt64(0))

    public init() {}

    public func add(_ bytes: Int) {
        guard bytes > 0 else { return }
        total.withLock { $0 &+= UInt64(bytes) }
    }

    public var bytes: UInt64 { total.withLock { $0 } }

    public func reset() { total.withLock { $0 = 0 } }
}
