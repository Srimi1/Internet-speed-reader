import Foundation

public enum TrafficDirection: String, Sendable, Equatable, Codable {
    case download
    case upload
}

/// Upload activity takes priority even while a faster download is running. Separate
/// entry/exit thresholds and measured dwell times avoid toggling on short control bursts.
public struct ActiveDirectionSelector: Sendable {
    public static let entryMbps: Double = 0.15
    public static let exitMbps: Double = 0.075
    public static let entrySeconds: Double = 2
    public static let exitSeconds: Double = 3

    public private(set) var current: TrafficDirection = .download
    private var entrySince: ContinuousClock.Instant?
    private var exitSince: ContinuousClock.Instant?

    public init() {}

    public mutating func update(
        downMbps: Double,
        upMbps: Double,
        uploadActivityMbps: Double? = nil,
        now: ContinuousClock.Instant
    ) -> TrafficDirection {
        let activity = uploadActivityMbps ?? upMbps
        guard downMbps.isFinite, upMbps.isFinite, activity.isFinite,
              max(downMbps, upMbps) >= Self.entryMbps else {
            // Actual idle immediately restores download; do not hold an old upload arrow.
            reset()
            return current
        }

        switch current {
        case .download:
            exitSince = nil
            guard activity >= Self.entryMbps else {
                entrySince = nil
                return current
            }
            if let entrySince {
                if now.seconds(since: entrySince) >= Self.entrySeconds {
                    current = .upload
                    self.entrySince = nil
                }
            } else {
                entrySince = now
            }
        case .upload:
            entrySince = nil
            guard activity < Self.exitMbps else {
                exitSince = nil
                return current
            }
            if let exitSince {
                if now.seconds(since: exitSince) >= Self.exitSeconds {
                    reset()
                }
            } else {
                exitSince = now
            }
        }
        return current
    }

    public mutating func reset() {
        current = .download
        entrySince = nil
        exitSince = nil
    }
}
