import Foundation

public enum TrafficDirection: String, Sendable, Equatable, Codable {
    case download
    case upload
}

/// Decides which single number the menu bar shows.
///
/// Download is the resting state, because that is what most traffic is and what people
/// mean by "my internet speed". It switches to upload only when upload genuinely
/// dominates, and then holds that choice for a moment.
///
/// The dwell time is the whole point. Without it the readout would flip between arrows
/// several times a second during any mixed transfer, since ACKs alone make the quiet
/// direction non-zero. A label that changes meaning faster than you can read it is
/// worse than one that is occasionally a second stale.
public struct ActiveDirectionSelector: Sendable {
    /// Upload must exceed download by this factor to take over the display.
    public static let dominanceRatio: Double = 1.3
    /// Below this, traffic is background chatter rather than a transfer worth showing.
    public static let floorMbps: Double = 0.15
    /// Once a direction wins it keeps the display at least this long.
    public static let dwellSeconds: Double = 3.0

    public private(set) var current: TrafficDirection = .download
    private var lastSwitch: ContinuousClock.Instant?

    public init() {}

    /// Returns the direction to display for this sample.
    public mutating func update(
        downMbps: Double,
        upMbps: Double,
        now: ContinuousClock.Instant
    ) -> TrafficDirection {
        let wanted = preferred(downMbps: downMbps, upMbps: upMbps)
        guard wanted != current else { return current }

        // Hold the current direction until the dwell time expires.
        if let lastSwitch, now.seconds(since: lastSwitch) < Self.dwellSeconds {
            return current
        }

        current = wanted
        lastSwitch = now
        return current
    }

    private func preferred(downMbps: Double, upMbps: Double) -> TrafficDirection {
        // Nothing meaningful is moving: rest on download rather than picking a winner
        // out of rounding noise.
        guard max(downMbps, upMbps) >= Self.floorMbps else { return .download }
        return upMbps > downMbps * Self.dominanceRatio ? .upload : .download
    }

    public mutating func reset() {
        current = .download
        lastSwitch = nil
    }
}
