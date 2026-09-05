import Foundation

/// Owns a run until its transport has finished cleaning up. UI cancellation alone
/// must not make a second run possible, or late callbacks can replace its result.
public struct SpeedTestRunGate: Sendable {
    public private(set) var activeID: UUID?
    public private(set) var isStopping = false
    private var nextAllowed: ContinuousClock.Instant?
    private var cloudflareAllowed: ContinuousClock.Instant?

    public init() {}

    public func remainingWait(at now: ContinuousClock.Instant, cloudflare: Bool) -> Double {
        let spacing = nextAllowed.map { max(0, $0.seconds(since: now)) } ?? 0
        let backoff = cloudflare ? (cloudflareAllowed.map { max(0, $0.seconds(since: now)) } ?? 0) : 0
        return max(spacing, backoff)
    }

    public func isRateLimited(at now: ContinuousClock.Instant) -> Bool {
        cloudflareAllowed.map { $0 > now } ?? false
    }

    public func canStart(at now: ContinuousClock.Instant, cloudflare: Bool) -> Bool {
        activeID == nil && remainingWait(at: now, cloudflare: cloudflare) == 0
    }

    public mutating func begin(at now: ContinuousClock.Instant, cloudflare: Bool) -> UUID? {
        guard canStart(at: now, cloudflare: cloudflare) else { return nil }
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
    public mutating func finish(_ id: UUID, at now: ContinuousClock.Instant, rateLimited: Bool = false) -> Bool {
        guard owns(id) else { return false }
        activeID = nil
        isStopping = false
        nextAllowed = now.advanced(by: .seconds(30))
        if rateLimited { cloudflareAllowed = now.advanced(by: .seconds(15 * 60)) }
        return true
    }
}
