import Foundation

/// A snapshot of one interface's cumulative byte counters.
public struct IFCounters: Sendable, Equatable {
    public let rx: UInt64
    public let tx: UInt64
    /// Packet counts supply a conservative control-traffic allowance per direction, so a
    /// stream of acknowledgements is not mistaken for payload moving the other way.
    public let txPackets: UInt64
    public let rxPackets: UInt64

    public init(rx: UInt64, tx: UInt64, txPackets: UInt64 = 0, rxPackets: UInt64 = 0) {
        self.rx = rx
        self.tx = tx
        self.txPackets = txPackets
        self.rxPackets = rxPackets
    }
}

public protocol CounterSource: Sendable {
    /// Counters for one interface index, or nil if that interface is gone.
    func counters(forInterfaceIndex index: Int) -> IFCounters?
    /// Counters for every interface, keyed by index.
    func allCounters() -> [Int: IFCounters]
}
