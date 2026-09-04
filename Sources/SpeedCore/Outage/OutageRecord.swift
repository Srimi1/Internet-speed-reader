import Foundation

public enum OutageCause: String, Sendable, Codable, Equatable {
    case probeFailed
    case pathUnsatisfied
    case captivePortal
}

public enum OutageEnd: String, Sendable, Codable, Equatable {
    case recovered
    case sleep
    case quit
    case crash
}

public struct OutageRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var schemaVersion: Int
    /// Stamped at the FIRST failed probe, not the second one that confirmed it,
    /// so the duration a user reads is honest.
    public var start: Date
    public var confirmedAt: Date?
    public var end: Date?
    public var interfaceName: String?
    public var cause: OutageCause
    public var unsatisfiedReason: String?
    public var failureKinds: [ProbeFailureKind]
    public var notified: Bool
    public var endReason: OutageEnd?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        start: Date,
        confirmedAt: Date? = nil,
        end: Date? = nil,
        interfaceName: String? = nil,
        cause: OutageCause,
        unsatisfiedReason: String? = nil,
        failureKinds: [ProbeFailureKind] = [],
        notified: Bool = false,
        endReason: OutageEnd? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.start = start
        self.confirmedAt = confirmedAt
        self.end = end
        self.interfaceName = interfaceName
        self.cause = cause
        self.unsatisfiedReason = unsatisfiedReason
        self.failureKinds = failureKinds
        self.notified = notified
        self.endReason = endReason
    }

    public var isOpen: Bool { end == nil }

    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}
