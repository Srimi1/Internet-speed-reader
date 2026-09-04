import Foundation

/// A snapshot of one interface's cumulative byte counters.
public struct IFCounters: Sendable, Equatable {
    public let rx: UInt64
    public let tx: UInt64

    public init(rx: UInt64, tx: UInt64) {
        self.rx = rx
        self.tx = tx
    }
}

public protocol CounterSource: Sendable {
    /// Counters for one interface index, or nil if that interface is gone.
    func counters(forInterfaceIndex index: Int) -> IFCounters?
    /// Counters for every interface, keyed by index.
    func allCounters() -> [Int: IFCounters]
}
