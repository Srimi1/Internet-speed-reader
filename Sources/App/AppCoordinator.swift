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
    var activeDirection: TrafficDirection = .download
    var activeInterface: PathSnapshot.Interface?
    var path: PathSnapshot = .unknown
    var liveReadingsAvailable = false
    var liveStatusText = "Waiting for a reading"
    private var lastSampleAt: ContinuousClock.Instant?
    private var currentInterval: Double = 1
    private var isSleeping = false
    private var measuringCapacity = false
    private var hasStarted = false
    private var isShuttingDown = false
    private var preparedForTermination = false

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
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerObserver: PowerPolicyObserver?
    @ObservationIgnored private var settingsWindowController: SettingsWindowController?

    private var smoother = ThroughputSmoother()
    private var directionSelector = ActiveDirectionSelector()

    init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        notifications.bootstrap()
        loginItem.refresh()
        reconcileLaunchAtLogin()

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
        settings.onRefreshPolicyChange = { [weak self] in self?.updatePowerPolicy() }
        powerObserver = PowerPolicyObserver { [weak self] in self?.updatePowerPolicy() }
        powerObserver?.start()
    }

    func prepareForTermination() async {
        isShuttingDown = true
        await speedTest.cancelAndWait()
        await monitor.stop()
        await outageEngine?.shutdown()
        preparedForTermination = true
    }

    func shutdown() {
        speedTest.cancel()
        powerObserver?.stop()
        powerObserver = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        settings.onRefreshPolicyChange = nil
        Task { await monitor.stop() }
        if !preparedForTermination, let engine = outageEngine {
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
        speedTest.onRunEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                guard !self.isSleeping else { return }
                self.measuringCapacity = true
                self.connectionState = .testing
                await self.monitor.setDuringTest(true)
                await self.outageEngine?.speedTestStarted()
            case .finished:
                self.measuringCapacity = false
                self.connectionState = .unknown
                await self.monitor.setDuringTest(false)
                guard !self.isShuttingDown else { return }
                if self.isSleeping {
                    await self.outageEngine?.willSleep()
                } else {
                    // A completed throughput test is not a connectivity probe; failures
                    // and cancellations especially must not manufacture an online event.
                    await self.outageEngine?.speedTestFinished(success: false)
                    await self.outageEngine?.pathChanged(self.path)
                    // The engine schedules its own uncancelled probe. Running a probe
                    // inline here would inherit a stopped test's cancellation.
                }
            }
        }
    }

    var canRunSpeedTest: Bool {
        path.status == .satisfied && !isSleeping && !isShuttingDown && connectionState != .captivePortal && speedTest.canStart
    }

    var canRunAppleTest: Bool {
        path.status == .satisfied && !isSleeping && !isShuttingDown && connectionState != .captivePortal && speedTest.canStartApple
    }

    func startSpeedTest() {
        guard canRunSpeedTest else { return }
        speedTest.start(interfaceName: activeInterface?.name, options: settings.speedTestOptions)
    }

    func startAppleDeepTest() {
        guard canRunAppleTest else { return }
        speedTest.startAppleDeepTest(interfaceName: activeInterface?.name, maxSeconds: settings.appleMaxSeconds)
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
        loginItem.refresh()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(coordinator: self)
        }
        settingsWindowController?.show()
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
            connectionState = measuringCapacity && !isSleeping ? .testing : Self.display(for: state)
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
        currentInterval = PowerPolicy.currentInterval(policy: settings.refreshPolicy)
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let updates = await monitor.updates()
            await monitor.setCadence(.seconds(self.currentInterval))
            await monitor.start()
            for await update in updates {
                switch update {
                case let .sample(sample):
                    guard !self.isSleeping, sample.interfaceName == self.activeInterface?.name else { continue }
                    self.ingest(sample)
                case let .unavailable(reason):
                    self.resetLiveDisplay(message: reason == .paused
                        ? "Paused while the Mac sleeps" : "Waiting for a fresh reading")
                    if reason == .stale, !self.isSleeping, !self.isShuttingDown { await monitor.start() }
                }
            }
        })
    }

    private func ingest(_ sample: ThroughputSample) {
        let smoothed = smoother.update(
            downMbps: sample.downMbps, upMbps: sample.upMbps, elapsedSeconds: sample.elapsedSeconds
        )
        downMbps = smoothed.downMbps
        upMbps = smoothed.upMbps
        samples.append(sample)
        lastSampleAt = sample.at
        liveReadingsAvailable = true
        liveStatusText = "Live traffic · all apps"
        let previousDirection = activeDirection
        activeDirection = directionSelector.update(
            downMbps: sample.downMbps, upMbps: sample.upMbps,
            uploadActivityMbps: sample.uploadActivityMbps, now: sample.at
        )
        if activeDirection != previousDirection {
            Log.live.debug("menu bar direction changed to \(self.activeDirection.rawValue, privacy: .public)")
        }
        Log.live.debug("sample on \(sample.interfaceName, privacy: .public): down=\(sample.downMbps) up=\(sample.upMbps) activity=\(sample.uploadActivityMbps) elapsed=\(sample.elapsedSeconds)")
    }

    private func resetLiveDisplay(message: String) {
        Log.live.debug("live reading unavailable: \(message, privacy: .public)")
        smoother.reset()
        directionSelector.reset()
        downMbps = 0
        upMbps = 0
        activeDirection = .download
        liveReadingsAvailable = false
        lastSampleAt = nil
        liveStatusText = message
        samples = RingBuffer<ThroughputSample>(capacity: 120)
    }

    /// The menu bar owns a refresh loop even while its panel is closed.
    func refreshTimeSensitiveState() {
        speedTest.refreshTime()
        if let lastSampleAt, time.now().seconds(since: lastSampleAt) > ThroughputCalculator.maximumGapSeconds(expectedIntervalSeconds: currentInterval) {
            resetLiveDisplay(message: "Reading unavailable · reconnecting")
            Task { await monitor.resetBaseline() }
        }
        if let until = alertsPausedUntil, until <= time.wallClock() { pauseAlerts(until: nil) }
    }

    private func updatePowerPolicy() {
        let interval = PowerPolicy.currentInterval(policy: settings.refreshPolicy)
        guard interval != currentInterval else { return }
        currentInterval = interval
        resetLiveDisplay(message: "Updating refresh interval")
        Task { await monitor.setCadence(.seconds(interval)) }
    }

    /// Makes the system registration match what the user wants, every launch.
    ///
    /// Every launch, not just the first: the background task database records the bundle
    /// it registered, and replacing the bundle on reinstall leaves that record pointing
    /// at nothing. The status then reads `.notFound` and the app quietly stops launching
    /// at login. Re-registering is idempotent, so doing it each time costs nothing.
    private func reconcileLaunchAtLogin() {
        guard LoginItemManager.isInApplicationsFolder else { return }
        loginItem.refresh()
        switch (settings.launchAtLoginWanted, loginItem.state) {
        case (true, .enabled), (true, .requiresApproval):
            break
        case (true, .disabled), (true, .notFound):
            loginItem.setEnabled(true)
        case (false, .enabled), (false, .notFound), (false, .requiresApproval):
            loginItem.setEnabled(false)
        case (false, .disabled):
            break
        }
    }

    // MARK: - Path

    private func startPathObservation() {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.pathSource.snapshots() {
                await self.apply(snapshot)
            }
        })
    }

    private func apply(_ snapshot: PathSnapshot) async {
        // NWPathSource deduplicates native NWPath equality before incrementing its
        // generation, including route changes that keep the same physical adapter.
        let changed = snapshot.generation != path.generation
            || snapshot.status != path.status || snapshot.interfaces != path.interfaces
            || snapshot.isExpensive != path.isExpensive || snapshot.isConstrained != path.isConstrained
        let selected = snapshot.status == .satisfied ? snapshot.activeInterface : nil
        let interfaceChanged = selected?.index != activeInterface?.index
        path = snapshot
        activeInterface = selected
        if changed {
            speedTest.cancel(reason: "Network changed. Run a new test on this connection.")
            resetLiveDisplay(message: selected == nil ? "No network interface" : "Waiting for a fresh reading")
            if let selected {
                if interfaceChanged {
                    await monitor.setInterface(name: selected.name, index: selected.index)
                } else {
                    await monitor.resetBaseline()
                }
            } else {
                await monitor.clearInterface()
            }
        }
        await outageEngine?.pathChanged(snapshot)
    }

    // MARK: - Sleep and wake

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.willSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.didWake() }
        })
    }

    private func willSleep() async {
        isSleeping = true
        measuringCapacity = false
        connectionState = .unknown
        speedTest.cancel(reason: "Test interrupted because the Mac went to sleep.")
        resetLiveDisplay(message: "Paused while the Mac sleeps")
        await monitor.pause()
        await outageEngine?.willSleep()
    }

    private func didWake() async {
        isSleeping = false
        resetLiveDisplay(message: "Resuming live monitoring")
        updatePowerPolicy()
        await monitor.resetBaseline()
        await monitor.start()
        await outageEngine?.didWake()
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
        let wanted = !loginItem.state.isOn
        settings.launchAtLoginWanted = wanted
        loginItem.setEnabled(wanted)
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
