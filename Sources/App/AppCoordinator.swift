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

    let settings = AppSettings()

    // Outages
    var outages: [OutageRecord] = []
    var currentOutageStart: Date?
    var alertsPausedUntil: Date?

    let notifications = NotificationService()
    let loginItem = LoginItemManager()
    let speedTest = SpeedTestController()

    private let time: any TimeSource = SystemTimeSource()
    let monitor = LiveThroughputMonitor()
    private let pathSource: any PathSource = NWPathSource()
    private var outageEngine: OutageEngine?
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
        wireSpeedTest()
        observeWorkspaceNotifications()
        startOutageEngine()
        startPathObservation()
        startLiveMeter()
    }

    func shutdown() {
        if let engine = outageEngine {
            // Synchronously give the engine a chance to close an open outage as a clean
            // quit, so it is not later mistaken for a crash.
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { await engine.shutdown(); semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 1.5)
        }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Speed test

    private func wireSpeedTest() {
        speedTest.onStateChange = { [weak self] running in
            guard let self else { return }
            // Suspend outage detection during a test: our own traffic saturating the link
            // must never be mistaken for a connectivity problem.
            self.connectionState = running ? .testing : self.connectionState
            guard let engine = self.outageEngine else { return }
            Task {
                if running { await engine.speedTestStarted() }
                else { await engine.speedTestFinished(success: true) }
            }
            Task { await self.monitor.setDuringTest(running) }
        }
    }

    func startSpeedTest() {
        speedTest.start(interfaceName: activeInterface?.name, options: settings.speedTestOptions)
    }

    func startAppleDeepTest() {
        speedTest.startAppleDeepTest(interfaceName: activeInterface?.name)
    }

    func clearOutages() {
        guard let engine = outageEngine else { return }
        Task {
            await engine.clearOutages()
            outages = []
        }
    }

    func clearHistory() {
        speedTest.clearHistory()
    }

    var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked yet"
        case .provisional: return "Provisional"
        default: return "Unknown"
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    var dataEstimateText: String {
        let down = speedTest.latestResult?.downloadMbps ?? 100
        let up = speedTest.latestResult?.uploadMbps ?? 20
        let bytes = settings.estimatedBytesPerTest(downMbps: down, upMbps: up)
        return String(format: "About %.0f MB per test at your last measured speed.", bytes / 1e6)
    }

    func openSettings() {
        NSApp.activate()
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Internet Speed Reader",
            .credits: NSAttributedString(
                string: "Measures against Cloudflare's public speed endpoints and Apple's networkQuality.\nApache-2.0 · github.com/Srimi1/Internet-speed-reader",
                attributes: [.font: NSFont.systemFont(ofSize: 10)]
            ),
        ])
    }

    // MARK: - Outage engine

    private func startOutageEngine() {
        let ledger: OutageLedger
        do {
            ledger = try OutageLedger.makeDefault()
        } catch {
            Log.outage.error("cannot open outage ledger: \(error.localizedDescription, privacy: .public)")
            return
        }

        let engine = OutageEngine(prober: HTTPProber(), ledger: ledger)
        outageEngine = engine

        tasks.append(Task { [weak self] in
            let events = await engine.events()
            await engine.start()
            for await event in events {
                guard let self else { return }
                await self.handle(event, engine: engine)
            }
        })
    }

    private func handle(_ event: OutageEvent, engine: OutageEngine) async {
        switch event {
        case let .stateChanged(state):
            connectionState = Self.display(for: state)
            currentOutageStart = (state == .down || state == .captivePortal) ? currentOutageStart : nil

        case let .notifyDown(record):
            currentOutageStart = record.start
            let interface = record.interfaceName.map { " on \($0)" } ?? ""
            let detail = record.unsatisfiedReason ?? "No internet connection"
            await notifications.post(
                identifier: NotificationService.Identifier.down,
                title: "Internet connection lost",
                body: "\(detail)\(interface), since \(Self.timeString(record.start))."
            )

        case let .notifyUp(record):
            let duration = DurationFormatter.humanReadable(record.duration(now: record.end ?? Date()))
            await notifications.post(
                identifier: NotificationService.Identifier.up,
                title: "Internet is back",
                body: "Restored after \(duration), down since \(Self.timeString(record.start)).",
                replacing: [NotificationService.Identifier.down]
            )

        case .ledgerChanged:
            outages = await engine.outages().sorted { $0.start > $1.start }
        }
    }

    private static func display(for state: ConnectivityStateMachine.State) -> ConnectionDisplayState {
        switch state {
        case .unknown: return .unknown
        case .online: return .online
        case .suspect: return .suspect
        case .down: return .offline
        case .captivePortal: return .captivePortal
        case .suspended: return .unknown
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func checkConnectionNow() {
        guard let engine = outageEngine else { return }
        Task { await engine.checkNow() }
    }

    func pauseAlerts(until date: Date?) {
        alertsPausedUntil = date
        guard let engine = outageEngine else { return }
        let paused = date != nil
        Task { await engine.setAlertsPaused(paused) }
    }

    var alertsArePaused: Bool {
        guard let until = alertsPausedUntil else { return false }
        return until > Date()
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

        if let engine = outageEngine {
            Task { await engine.pathChanged(snapshot) }
        }

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

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            let engine = self?.outageEngine
            Task {
                await monitor.pause()
                await engine?.willSleep()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // A stale baseline across a sleep would render the whole gap as one giant burst.
            let engine = self?.outageEngine
            Task {
                await monitor.resetBaseline()
                await monitor.start()
                await engine?.didWake()
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
