import Foundation
import os

/// Provisional progress across all streams on one shared clock. Final results use
/// ConfirmedPayloadLedger so failed and unconfirmed requests cannot become headline speed.
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
