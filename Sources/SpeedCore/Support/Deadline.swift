import Foundation

public struct DeadlineExceeded: Error, Sendable {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
}

/// Races `work` against a timeout and throws `DeadlineExceeded` if the timeout wins.
///
/// This exists because URLSession and NWConnection can stay completely silent on a
/// blackholed route: verified locally that a connection to 192.0.2.1:443 produced no
/// state callback at all for 4+ seconds. Every network call in this app gets a deadline.
public func withDeadline<T: Sendable>(
    _ timeout: Duration,
    clock: any TimeSource,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: timeout, tolerance: .zero)
            throw DeadlineExceeded(seconds: timeout.seconds)
        }
        guard let first = try await group.next() else {
            throw DeadlineExceeded(seconds: timeout.seconds)
        }
        group.cancelAll()
        return first
    }
}
