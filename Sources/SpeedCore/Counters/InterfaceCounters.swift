import Foundation

/// A snapshot of one interface's cumulative byte counters.
public struct IFCounters: Sendable, Equatable {
    public let rx: UInt64
    public let tx: UInt64
    /// Packet count supplies a conservative control-traffic allowance for upload activity.
    public let txPackets: UInt64

    public init(rx: UInt64, tx: UInt64, txPackets: UInt64 = 0) {
        self.rx = rx
        self.tx = tx
        self.txPackets = txPackets
    }
}

public protocol CounterSource: Sendable {
    /// Counters for one interface index, or nil if that interface is gone.
    func counters(forInterfaceIndex index: Int) -> IFCounters?
    /// Counters for every interface, keyed by index.
    func allCounters() -> [Int: IFCounters]
}
