import AppKit
import Observation
import SpeedCore

/// Composition root. Owns the long-lived subsystems and mirrors their async streams
/// into main-actor state the UI observes.
@Observable
final class AppCoordinator {
    // Live meter
    var liveReadout = LiveReadoutModel.Presentation(
        downMbps: 0, upMbps: 0, freshness: .unavailable, message: "Waiting for a reading"
    )
    var samples = RingBuffer<ThroughputSample>(capacity: 120)
    var activeDirection: TrafficDirection = .download
    /// Which directions are transferring right now, for row emphasis in the menu bar.
    var downloadIsActive = false
    var uploadIsActive = false
    var activeInterface: PathSnapshot.Interface?
    var path: PathSnapshot = .unknown
    private var readout = LiveReadoutModel()
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
    private var downloadActivity = TransferActivityDetector()
    private var uploadActivity = TransferActivityDetector()
    /// Set by AppDelegate so a finished test can bring the panel back.
    @ObservationIgnored weak var panelPresenter: (any PanelPresenting)?

    init() {}

    /// Smoothed download rate currently on screen.
    var downMbps: Double { liveReadout.downMbps }
    var upMbps: Double { liveReadout.upMbps }
    var liveReadingsAvailable: Bool { liveReadout.hasReading }
    var liveStatusText: String { liveReadout.message }

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

        notifications.onRunTestRequested = { [weak self] in self?.startSpeedTest() }
        notifications.onShowLogRequested = { [weak self] in self?.panelPresenter?.showPanel() }

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
            case let .finished(outcome):
                self.measuringCapacity = false
                self.connectionState = .unknown
                await self.monitor.setDuringTest(false)
                guard !self.isShuttingDown else { return }
                if !self.isSleeping, self.settings.reopenPanelOnFinish,
                   outcome == .succeeded || outcome == .failed {
                    // After the controller has published its terminal state, so the
                    // reopened panel shows the result or the error, not the running gauge.
                    Task { @MainActor [weak self] in self?.panelPresenter?.reopenPanelForResult() }
                }
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
        pathAllowsTesting && speedTest.canStart(choice: settings.speedTestEngine)
    }

    private var pathAllowsTesting: Bool {
        path.status == .satisfied && !isSleeping && !isShuttingDown && connectionState != .captivePortal
    }

    /// Why GO is unavailable right now, or nil when it can run.
    var speedTestBlockedReason: String? {
        speedTest.startBlockedReason(choice: settings.speedTestEngine)
    }

    var canRunAppleTest: Bool {
        pathAllowsTesting && speedTest.canStartApple
    }

    func startSpeedTest() {
        guard canRunSpeedTest else { return }
        speedTest.start(
            choice: settings.speedTestEngine,
            request: settings.speedTestRequest(interfaceName: activeInterface?.name)
        )
    }

    /// Runs Apple's tool alone, as a deliberate second opinion rather than a fallback.
    func startAppleDeepTest() {
        guard canRunAppleTest else { return }
        speedTest.start(
            choice: .apple,
            request: settings.speedTestRequest(interfaceName: activeInterface?.name)
        )
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
                    self.holdLiveDisplay(reason)
                    if reason == .stale, !self.isSleeping, !self.isShuttingDown { await monitor.start() }
                }
            }
        })
    }

    private func ingest(_ sample: ThroughputSample) {
        let smoothed = smoother.update(
            downMbps: sample.downMbps, upMbps: sample.upMbps, elapsedSeconds: sample.elapsedSeconds
        )
        readout.sample(downMbps: smoothed.downMbps, upMbps: smoothed.upMbps, at: sample.at)
        samples.append(sample)

        // Activity detectors see raw values: smoothing exists to steady the display, and
        // feeding a smoothed rate into a byte-volume window would understate short bursts.
        let wasDownloading = downloadIsActive
        let wasUploading = uploadIsActive
        downloadIsActive = downloadActivity.update(
            activityMbps: sample.downloadActivityMbps, elapsedSeconds: sample.elapsedSeconds, now: sample.at
        ) == .active
        uploadIsActive = uploadActivity.update(
            activityMbps: sample.uploadActivityMbps, elapsedSeconds: sample.elapsedSeconds, now: sample.at
        ) == .active
        if wasDownloading != downloadIsActive {
            Log.live.debug("download activity \(self.downloadIsActive ? "active" : "idle", privacy: .public)")
        }
        if wasUploading != uploadIsActive {
            Log.live.debug("upload activity \(self.uploadIsActive ? "active" : "idle", privacy: .public)")
        }

        let previousDirection = activeDirection
        activeDirection = directionSelector.update(
            downMbps: sample.downMbps, upMbps: sample.upMbps,
            uploadActivityMbps: sample.uploadActivityMbps, now: sample.at
        )
        if activeDirection != previousDirection {
            Log.live.debug("menu bar direction changed to \(self.activeDirection.rawValue, privacy: .public)")
        }
        publishReadout()
        Log.live.debug("sample on \(sample.interfaceName, privacy: .public): down=\(sample.downMbps) up=\(sample.upMbps) activity=\(sample.uploadActivityMbps) elapsed=\(sample.elapsedSeconds)")
    }

    /// A reading is briefly missing. The last numbers stay on screen, dimmed, rather than
    /// being replaced by a dash for what is usually one late tick.
    private func holdLiveDisplay(_ reason: LiveThroughputUnavailableReason) {
        readout.unavailable(reason, at: time.now(), expectedIntervalSeconds: currentInterval)
        publishReadout()
        Log.live.debug("live reading unavailable: \(self.liveReadout.message, privacy: .public)")
    }

    /// The source itself changed or went away: clear everything derived from it.
    private func clearLiveDisplay(message: String) {
        Log.live.debug("live display cleared: \(message, privacy: .public)")
        smoother.reset()
        directionSelector.reset()
        downloadActivity.reset()
        uploadActivity.reset()
        downloadIsActive = false
        uploadIsActive = false
        activeDirection = .download
        readout.reset(message: message)
        samples = RingBuffer<ThroughputSample>(capacity: 120)
        publishReadout()
    }

    private func publishReadout() {
        liveReadout = readout.presentation(now: time.now())
    }

    /// The menu bar owns a refresh loop even while its panel is closed.
    func refreshTimeSensitiveState() {
        speedTest.refreshTime()
        publishReadout()
        // Fires at most once per staleness episode: this loop runs faster than the
        // sampling cadence, and repeatedly dropping the baseline would stop the monitor
        // from ever building a delta.
        if readout.needsRebaseline(now: time.now(), expectedIntervalSeconds: currentInterval) {
            Log.live.debug("live meter stale; requesting a fresh baseline")
            Task { await monitor.resetBaseline() }
        }
        if let until = alertsPausedUntil, until <= time.wallClock() { pauseAlerts(until: nil) }
    }

    private func updatePowerPolicy() {
        let interval = PowerPolicy.currentInterval(policy: settings.refreshPolicy)
        guard interval != currentInterval else { return }
        currentInterval = interval
        // A cadence change is not a network change: keep the last reading while the
        // sampler re-establishes its baseline at the new interval.
        holdLiveDisplay(.starting)
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
        // NWPath equality fails for DNS, gateway and address changes, so a new snapshot
        // arrives for events that leave the measured interface untouched. Only a change
        // to the interface itself may disturb the meter.
        let change = PathChangeClassifier.classify(previous: path, current: snapshot)
        let selected = snapshot.status == .satisfied ? snapshot.activeInterface : nil
        path = snapshot
        activeInterface = selected

        if change != .none {
            Log.live.debug("path change: \(change.rawValue, privacy: .public)")
        }
        if change.invalidatesRunningTest {
            // A capacity test must describe one network, so even a route-only change ends it.
            speedTest.cancel(reason: "Network changed. Run a new test on this connection.")
        }
        if change.requiresInterfaceRebind {
            clearLiveDisplay(message: selected == nil ? "No network interface" : "Waiting for a fresh reading")
            if let selected {
                await monitor.setInterface(name: selected.name, index: selected.index)
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
        clearLiveDisplay(message: "Paused while the Mac sleeps")
        await monitor.pause()
        await outageEngine?.willSleep()
    }

    private func didWake() async {
        isSleeping = false
        clearLiveDisplay(message: "Resuming live monitoring")
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
