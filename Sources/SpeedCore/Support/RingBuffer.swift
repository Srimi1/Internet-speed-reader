import Foundation

/// Fixed-capacity FIFO used for the live sparkline samples.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer needs a positive capacity")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: true) }

    public var elements: [Element] { storage }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Element? { storage.last }
}
