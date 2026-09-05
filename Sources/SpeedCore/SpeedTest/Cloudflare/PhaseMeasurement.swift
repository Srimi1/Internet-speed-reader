import Foundation
import os

/// Reservations include every in-flight request. Checking only bytes already received
/// lets all streams overshoot a data cap together by an entire chunk.
final class PhaseByteBudget: Sendable {
    private struct State { var reserved: UInt64 = 0; var limited = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let ceiling: UInt64

    init(ceiling: UInt64) { self.ceiling = ceiling }

    func reserve(preferredBytes: Int, allowedSizes: [Int]? = nil) -> Int? {
        state.withLock { state in
            let remaining = ceiling - state.reserved
            guard remaining > 0, preferredBytes > 0 else {
                state.limited = true
                return nil
            }
            let maximum = min(remaining, UInt64(preferredBytes))
            let bytes: UInt64
            if let allowedSizes {
                guard let size = allowedSizes.filter({ $0 > 0 && UInt64($0) <= maximum }).max() else {
                    state.limited = true
                    return nil
                }
                bytes = UInt64(size)
            } else { bytes = maximum }
            state.reserved += bytes
            if state.reserved == ceiling { state.limited = true }
            return Int(bytes)
        }
    }

    var reservedBytes: UInt64 { state.withLock { $0.reserved } }
    var isLimited: Bool { state.withLock { $0.limited } }
}

struct TimedPayload: Sendable {
    let seconds: Double
    let bytes: Int
}

/// A request keeps its original callback times until validation. Committing a whole
/// upload at response time would create a fake spike and shift warm-up bytes forward.
final class RequestPayloadTimeline: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [TimedPayload]())
    private let time: any TimeSource
    private let phaseStart: ContinuousClock.Instant

    init(time: any TimeSource, phaseStart: ContinuousClock.Instant) {
        self.time = time
        self.phaseStart = phaseStart
    }

    func record(_ bytes: Int) {
        guard bytes > 0 else { return }
        let seconds = max(0, time.now().seconds(since: phaseStart))
        events.withLock { $0.append(TimedPayload(seconds: seconds, bytes: bytes)) }
    }

    var snapshot: [TimedPayload] { events.withLock { $0 } }
}

final class ConfirmedPayloadLedger: Sendable {
    private struct State { var bytes: UInt64 = 0; var events: [TimedPayload] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    static let intervalSeconds = 0.1

    func confirm(_ events: [TimedPayload], expectedBytes: Int) throws {
        let count = events.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.bytes)) }
        guard count == UInt64(expectedBytes) else {
            throw SpeedTestError.engineFailure("Payload timing did not match the confirmed byte count")
        }
        state.withLock { state in
            state.bytes += count
            state.events.append(contentsOf: events)
        }
    }

    var bytes: UInt64 { state.withLock { $0.bytes } }

    /// Empty intervals remain in the timeline, including the final acknowledgement
    /// drain. Real stalls are part of the delivered rate, not outliers to remove.
    func slices(until seconds: Double) -> [ThroughputSlice] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        let events = state.withLock { $0.events }
        let count = max(1, Int(ceil(seconds / Self.intervalSeconds)))
        var bytes = [UInt64](repeating: 0, count: count)
        for event in events where event.seconds <= seconds {
            let index = min(count - 1, max(0, Int(max(0, event.seconds - 1e-9) / Self.intervalSeconds)))
            bytes[index] += UInt64(event.bytes)
        }
        return (0..<count).compactMap { index in
            let start = Double(index) * Self.intervalSeconds
            let end = min(seconds, Double(index + 1) * Self.intervalSeconds)
            let duration = end - start
            guard duration > 0 else { return nil }
            return ThroughputSlice(mbps: Double(bytes[index]) * 8 / 1e6 / duration,
                                   secondsSincePhaseStart: end, durationSeconds: duration)
        }
    }
}

final class PhaseStopState: Sendable {
    private struct State { var drainExpired = false; var incomplete = false; var largestChunk = 0; var networkProtocol: String? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func expireDrain() { state.withLock { $0.drainExpired = true } }
    func markIncomplete() { state.withLock { $0.incomplete = true } }
    func record(chunk: Int, networkProtocol: String?) {
        state.withLock {
            $0.largestChunk = max($0.largestChunk, chunk)
            if let networkProtocol { $0.networkProtocol = networkProtocol }
        }
    }
    var drainExpired: Bool { state.withLock { $0.drainExpired } }
    var incomplete: Bool { state.withLock { $0.incomplete } }
    var largestChunk: Int { state.withLock { $0.largestChunk } }
    var networkProtocol: String? { state.withLock { $0.networkProtocol } }
}
