import AppKit
import Observation
import SpeedCore

/// Composition root. Owns the long-lived subsystems and mirrors their async streams
/// into main-actor state the UI observes.
@Observable
final class AppCoordinator {
    // Live meter
    var downMbps: Double = 0
    var upMbps: Double = 0
    var isLiveMeterRunning = false

    // Connectivity
    var connectionState: ConnectionDisplayState = .unknown

    private let time: any TimeSource = SystemTimeSource()

    init() {}

    func start() {
        isLiveMeterRunning = true
    }

    func shutdown() {
        isLiveMeterRunning = false
    }
}

enum ConnectionDisplayState: Equatable {
    case unknown
    case online
    case suspect
    case offline
    case captivePortal
    case testing

    var dotColor: NSColor {
        switch self {
        case .unknown: return .tertiaryLabelColor
        case .online: return .systemGreen
        case .suspect: return .systemOrange
        case .offline, .captivePortal: return .systemRed
        case .testing: return .systemBlue
        }
    }

    var textIsRed: Bool {
        self == .offline || self == .captivePortal
    }
}
