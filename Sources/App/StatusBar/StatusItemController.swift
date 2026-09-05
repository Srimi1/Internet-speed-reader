import AppKit
import SpeedCore
import SwiftUI

/// Somewhere the panel can be shown from, without the coordinator knowing about AppKit.
@MainActor
protocol PanelPresenting: AnyObject {
    func showPanel()
    /// Brings the panel back when a test finishes while it is closed.
    func reopenPanelForResult()
}

/// Owns the NSStatusItem, its custom view, and click routing.
///
/// AppKit rather than SwiftUI's MenuBarExtra: the SwiftUI label is limited to text or
/// text+image, its popover cannot be dismissed programmatically, and it offers no
/// right-click. All three are requirements here.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, PanelPresenting {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private let readout = StatusItemView()
    private var refreshTask: Task<Void, Never>?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        // .transient closes when the user clicks elsewhere, which is the behaviour people
        // expect from a menu bar item. A running test keeps going in the coordinator.
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PanelView().environment(coordinator)
        )
        return popover
    }()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: 72)
        super.init()

        statusItem.autosaveName = "com.srimi.internetspeedreader.readout"
        // Never leave the item hidden by a stale persisted flag: the app has no other
        // always-visible surface, so an invisible item reads as a dead app.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Internet speed")
            button.setAccessibilityIdentifier("internet-speed-reader")

            readout.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(readout)
            NSLayoutConstraint.activate([
                readout.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                readout.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                readout.topAnchor.constraint(equalTo: button.topAnchor),
                readout.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        applyWidth()
        startRefreshLoop()
    }

    deinit { refreshTask?.cancel() }

    /// Pull the observable state on a timer rather than pushing from the coordinator:
    /// the bar only needs to repaint a few times a second, and this keeps the drawing
    /// code out of the sampling path.
    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(150))
            }
        }
    }

    private var lastWidthKey = ""
    private var lastTooltip = ""

    private func refresh() {
        coordinator.refreshTimeSensitiveState()
        let settings = coordinator.settings
        let widthKey = "\(settings.barLayout.rawValue)|\(settings.unit.rawValue)|\(settings.showUnits)"
        if widthKey != lastWidthKey {
            lastWidthKey = widthKey
            applyWidth()
        }
        let live = coordinator.liveReadout
        let hasReading = live.hasReading
        readout.model = StatusItemRenderModel(
            downText: hasReading ? SpeedFormatter.bar(live.downMbps, unit: settings.unit) : SpeedFormatter.unavailable,
            upText: hasReading ? SpeedFormatter.bar(live.upMbps, unit: settings.unit) : SpeedFormatter.unavailable,
            downEmphasis: emphasis(isActive: coordinator.downloadIsActive, otherIsActive: coordinator.uploadIsActive),
            upEmphasis: emphasis(isActive: coordinator.uploadIsActive, otherIsActive: coordinator.downloadIsActive),
            freshness: live.freshness,
            activeDirection: coordinator.activeDirection,
            state: coordinator.connectionState,
            layout: settings.barLayout,
            showUnits: settings.showUnits,
            unit: settings.unit
        )
        // Reassigning the tooltip restarts AppKit's hover timer, so only do it on change.
        let tip = tooltip()
        if tip != lastTooltip {
            lastTooltip = tip
            statusItem.button?.toolTip = tip
        }
        statusItem.button?.setAccessibilityValue(readout.accessibilityValue())
    }

    private func emphasis(isActive: Bool, otherIsActive: Bool) -> RowEmphasis {
        if isActive { return .active }
        return otherIsActive ? .muted : .normal
    }

    private func applyWidth() {
        let width = StatusItemView.width(
            for: coordinator.settings.barLayout,
            showUnits: coordinator.settings.showUnits,
            unit: coordinator.settings.unit
        )
        statusItem.length = width
        // Recorded so the installed-app check can compare layouts on a crowded menu bar
        // instead of relying on an estimate.
        Log.app.info("status item width=\(width) layout=\(self.coordinator.settings.barLayout.rawValue, privacy: .public) unit=\(self.coordinator.settings.unit.rawValue, privacy: .public)")
    }

    private func tooltip() -> String {
        let unit = coordinator.settings.unit
        let live = coordinator.liveReadout
        var lines = ["Internet Speed Reader"]
        if live.hasReading {
            let down = SpeedFormatter.bar(live.downMbps, unit: unit)
            let up = SpeedFormatter.bar(live.upMbps, unit: unit)
            lines.append("↓ \(down) · ↑ \(up) \(unit.shortLabel) now")
        } else {
            lines.append(coordinator.liveStatusText)
        }
        if let interface = coordinator.activeInterface {
            let kind = interface.kind == .tunnel ? "VPN tunnel payload" : interface.kind.rawValue
            lines.append("Live on \(interface.name) (\(kind)), all apps")
        }
        if let result = coordinator.speedTest.latestResult {
            let provider = result.engine == .cloudflare ? "Cloudflare" : "Apple"
            let down = result.downloadMbps.map { SpeedFormatter.bar($0, unit: unit) } ?? SpeedFormatter.unavailable
            let up = result.uploadMbps.map { SpeedFormatter.bar($0, unit: unit) } ?? SpeedFormatter.unavailable
            lines.append("Last test ↓ \(down) · ↑ \(up) \(unit.shortLabel) · \(provider)")
        }
        lines.append("Interface traffic includes protocol overhead and local traffic; GO measures test payload.")
        return lines.joined(separator: "\n")
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            button.highlight(false)
            return
        }
        // Opening the panel is a good moment to re-check connectivity.
        coordinator.checkConnectionNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func showPanel() {
        guard !popover.isShown else { return }
        togglePopover()
    }

    /// Called when a test finishes while the panel is closed, so the result is not missed.
    func reopenPanelForResult() {
        guard !popover.isShown, let button = statusItem.button, button.window != nil else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover can open unfocused and dismiss on the next click.
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    private func showContextMenu() {
        coordinator.loginItem.refresh()

        let menu = NSMenu()
        menu.delegate = self

        let runTest = NSMenuItem(title: "Run Speed Test", action: #selector(runSpeedTest), keyEquivalent: "")
        runTest.target = self
        runTest.isEnabled = coordinator.canRunSpeedTest
        menu.addItem(runTest)

        let appleTest = NSMenuItem(title: "Apple Deep Test", action: #selector(runAppleTest), keyEquivalent: "")
        appleTest.target = self
        appleTest.isEnabled = coordinator.canRunAppleTest
        menu.addItem(appleTest)

        let checkNow = NSMenuItem(title: "Check Connection Now", action: #selector(checkNow), keyEquivalent: "")
        checkNow.target = self
        menu.addItem(checkNow)

        menu.addItem(.separator())

        let pauseMenu = NSMenu()
        for (title, seconds) in [("1 Hour", 3600.0), ("Until Tomorrow", 86_400.0)] {
            let item = NSMenuItem(title: title, action: #selector(pauseAlerts(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            pauseMenu.addItem(item)
        }
        let resume = NSMenuItem(title: "Resume Alerts", action: #selector(resumeAlerts), keyEquivalent: "")
        resume.target = self
        pauseMenu.addItem(resume)

        let pauseItem = NSMenuItem(title: coordinator.alertsArePaused ? "Alerts Paused" : "Pause Alerts", action: nil, keyEquivalent: "")
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        let testItem = NSMenuItem(
            title: "Send Test Notification",
            action: #selector(sendTestNotification),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: loginItemTitle(),
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = coordinator.loginItem.state.isOn ? .on : .off
        menu.addItem(loginItem)

        let statusLine = NSMenuItem(
            title: "Notifications: \(authorizationDescription())",
            action: nil,
            keyEquivalent: ""
        )
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let locationLine = NSMenuItem(
            title: LoginItemManager.isInApplicationsFolder
                ? "Running from /Applications"
                : "Not in /Applications (login item is fragile)",
            action: nil,
            keyEquivalent: ""
        )
        locationLine.isEnabled = false
        menu.addItem(locationLine)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Internet Speed Reader", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Assign, click, then clear in menuDidClose so a left click still reaches our action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func loginItemTitle() -> String {
        switch coordinator.loginItem.state {
        case .enabled: return "Launch at Login"
        case .disabled: return "Launch at Login"
        case .requiresApproval: return "Launch at Login (approve in System Settings)"
        case .notFound: return "Launch at Login (reinstall needed)"
        }
    }

    private func authorizationDescription() -> String {
        switch coordinator.notifications.authorizationStatus {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .notDetermined: return "not asked yet"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    @objc private func sendTestNotification() { coordinator.sendTestNotification() }
    @objc private func toggleLoginItem() { coordinator.toggleLoginItem() }
    @objc private func runSpeedTest() { coordinator.startSpeedTest() }
    @objc private func runAppleTest() { coordinator.startAppleDeepTest() }
    @objc private func checkNow() { coordinator.checkConnectionNow() }
    @objc private func openSettings() { coordinator.openSettings() }
    @objc private func showAbout() { coordinator.showAbout() }

    @objc private func pauseAlerts(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        coordinator.pauseAlerts(until: Date().addingTimeInterval(seconds))
    }

    @objc private func resumeAlerts() { coordinator.pauseAlerts(until: nil) }
}
