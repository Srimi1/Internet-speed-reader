import Foundation

/// Owns a run until its transport has finished cleaning up. UI cancellation alone
/// must not make a second run possible, or late callbacks can replace its result.
///
/// Backoffs are per engine: one provider refusing must not silence the alternatives, and
/// a refusing provider must not be walked back into on the next press.
public struct SpeedTestRunGate: Sendable {
    public private(set) var activeID: UUID?
    public private(set) var isStopping = false
    private var nextAllowed: ContinuousClock.Instant?
    private var blockedUntil: [SpeedTestEngineKey: ContinuousClock.Instant] = [:]

    public init() {}

    /// Shared spacing between any two runs, whichever engines they used.
    public func spacingWait(at now: ContinuousClock.Instant) -> Double {
        nextAllowed.map { max(0, $0.seconds(since: now)) } ?? 0
    }

    public func isBlocked(_ engine: SpeedTestEngineKey, at now: ContinuousClock.Instant) -> Bool {
        blockedUntil[engine].map { $0 > now } ?? false
    }

    public func blockedEngines(at now: ContinuousClock.Instant) -> [SpeedTestEngineKey] {
        SpeedTestEngineKey.allCases.filter { isBlocked($0, at: now) }
    }

    /// How long before any of these engines can run again.
    public func remainingWait(at now: ContinuousClock.Instant, engines: [SpeedTestEngineKey]) -> Double {
        let spacing = spacingWait(at: now)
        guard !engines.isEmpty else { return spacing }
        let waits = engines.map { engine in
            blockedUntil[engine].map { max(0, $0.seconds(since: now)) } ?? 0
        }
        // The soonest engine decides: the chain skips whichever ones are still blocked.
        return max(spacing, waits.min() ?? 0)
    }

    public func canStart(at now: ContinuousClock.Instant, engines: [SpeedTestEngineKey]) -> Bool {
        activeID == nil && remainingWait(at: now, engines: engines) == 0
    }

    /// The engines worth trying right now, in the order given. Empty when they are all
    /// blocked, which the caller reports rather than silently retrying a refusal.
    public func availableEngines(at now: ContinuousClock.Instant, from engines: [SpeedTestEngineKey]) -> [SpeedTestEngineKey] {
        engines.filter { !isBlocked($0, at: now) }
    }

    public mutating func begin(at now: ContinuousClock.Instant, engines: [SpeedTestEngineKey]) -> UUID? {
        guard canStart(at: now, engines: engines) else { return nil }
        let id = UUID()
        activeID = id
        isStopping = false
        return id
    }

    public func acceptsProgress(from id: UUID) -> Bool { activeID == id && !isStopping }
    public func owns(_ id: UUID) -> Bool { activeID == id }

    @discardableResult
    public mutating func requestStop() -> Bool {
        guard activeID != nil, !isStopping else { return false }
        isStopping = true
        return true
    }

    @discardableResult
    public mutating func finish(
        _ id: UUID,
        at now: ContinuousClock.Instant,
        backoffs: [SpeedTestEngineKey: Duration] = [:]
    ) -> Bool {
        guard owns(id) else { return false }
        activeID = nil
        isStopping = false
        nextAllowed = now.advanced(by: .seconds(30))
        for (engine, duration) in backoffs {
            blockedUntil[engine] = now.advanced(by: duration)
        }
        return true
    }
}
