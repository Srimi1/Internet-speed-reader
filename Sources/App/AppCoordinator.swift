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
    var samples = RingBuffer<ThroughputSample>(capacity: 120)
    var activeInterface: PathSnapshot.Interface?
    var path: PathSnapshot = .unknown

    // Connectivity
    var connectionState: ConnectionDisplayState = .unknown

    // Preferences (persisted properly in M6)
    var barLayout: BarLayout = .twoLine
    var unit: SpeedUnit = .megabitsPerSecond
    var showUnitsInBar: Bool = false

    let notifications = NotificationService()
    let loginItem = LoginItemManager()

    private let time: any TimeSource = SystemTimeSource()
    private let monitor = LiveThroughputMonitor()
    private let pathSource: any PathSource = NWPathSource()
    private var tasks: [Task<Void, Never>] = []
    private var activity: NSObjectProtocol?

    /// Smoothing for the bar so it reads as a trend rather than flickering every tick.
    private var smoothedDown: Double = 0
    private var smoothedUp: Double = 0
    private static let smoothing = 0.5

    init() {}

    func start() {
        notifications.bootstrap()
        loginItem.refresh()

        Task { [notifications] in
            await notifications.refreshAuthorizationStatus()
            if notifications.authorizationStatus == .notDetermined {
                await notifications.requestAuthorization()
            }
        }

        beginActivity()
        observeWorkspaceNotifications()
        startPathObservation()
        startLiveMeter()
    }

    func shutdown() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Live meter

    private func startLiveMeter() {
        let monitor = self.monitor
        let stream = Task { await monitor.samples() }

        tasks.append(Task { [weak self] in
            let samples = await stream.value
            await monitor.setCadence(PowerPolicy.currentCadence())
            await monitor.start()
            for await sample in samples {
                guard let self else { return }
                self.ingest(sample)
            }
        })
    }

    private func ingest(_ sample: ThroughputSample) {
        smoothedDown = smoothedDown * (1 - Self.smoothing) + sample.downMbps * Self.smoothing
        smoothedUp = smoothedUp * (1 - Self.smoothing) + sample.upMbps * Self.smoothing
        downMbps = smoothedDown
        upMbps = smoothedUp
        samples.append(sample)
    }

    // MARK: - Path

    private func startPathObservation() {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.pathSource.snapshots() {
                self.apply(snapshot)
            }
        })
    }

    private func apply(_ snapshot: PathSnapshot) {
        path = snapshot
        let selected = snapshot.activeInterface
        let changed = selected?.index != activeInterface?.index
        activeInterface = selected

        // Provisional state until the outage engine lands in M4: an unsatisfied path is
        // trustworthy in the negative direction, but a satisfied one is not (a captive
        // portal satisfies the path with no internet behind it).
        connectionState = snapshot.status == .unsatisfied ? .offline : .online

        if changed {
            smoothedDown = 0
            smoothedUp = 0
            downMbps = 0
            upMbps = 0
            let monitor = self.monitor
            if let selected {
                Task { await monitor.setInterface(name: selected.name, index: selected.index) }
            } else {
                Task { await monitor.clearInterface() }
            }
        }
    }

    // MARK: - Sleep and wake

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let monitor = self.monitor

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await monitor.pause() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // A stale baseline across a sleep would render the whole gap as one giant burst.
            Task {
                await monitor.resetBaseline()
                await monitor.start()
            }
        }
    }

    private func beginActivity() {
        // The documented App Nap opt-out for work that must keep ticking.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Live link throughput"
        )
    }

    // MARK: - Spike actions (M1)

    func sendTestNotification() {
        Task { [notifications] in
            if notifications.authorizationStatus != .authorized {
                await notifications.requestAuthorization()
            }
            await notifications.post(
                identifier: "isr.test",
                title: "Internet Speed Reader",
                body: "Test notification. Alerts are working."
            )
        }
    }

    func toggleLoginItem() {
        if loginItem.state == .requiresApproval {
            loginItem.openSystemSettings()
            return
        }
        loginItem.setEnabled(!loginItem.state.isOn)
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

    var textIsRed: Bool { self == .offline || self == .captivePortal }

    var spokenDescription: String {
        switch self {
        case .unknown: return "checking"
        case .online: return "online"
        case .suspect: return "checking connection"
        case .offline: return "offline"
        case .captivePortal: return "sign-in required"
        case .testing: return "running a speed test"
        }
    }
}
