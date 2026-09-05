import AppKit
import SpeedCore
import SwiftUI

/// Owns the NSStatusItem, its custom view, and click routing.
///
/// AppKit rather than SwiftUI's MenuBarExtra: the SwiftUI label is limited to text or
/// text+image, its popover cannot be dismissed programmatically, and it offers no
/// right-click. All three are requirements here.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
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

    private func refresh() {
        coordinator.refreshTimeSensitiveState()
        let widthKey = "\(coordinator.settings.barLayout.rawValue)|\(coordinator.settings.unit.rawValue)|\(coordinator.settings.showUnits)"
        if widthKey != lastWidthKey {
            lastWidthKey = widthKey
            applyWidth()
        }
        readout.model = StatusItemRenderModel(
            downText: coordinator.liveReadingsAvailable ? SpeedFormatter.bar(coordinator.downMbps, unit: coordinator.settings.unit) : "—",
            upText: coordinator.liveReadingsAvailable ? SpeedFormatter.bar(coordinator.upMbps, unit: coordinator.settings.unit) : "—",
            activeDirection: coordinator.activeDirection,
            state: coordinator.connectionState,
            layout: coordinator.settings.barLayout,
            showUnits: coordinator.settings.showUnits,
            unit: coordinator.settings.unit
        )
        statusItem.button?.toolTip = tooltip()
        statusItem.button?.setAccessibilityValue(coordinator.liveReadingsAvailable
            ? "Download \(readout.model.downText), upload \(readout.model.upText) \(coordinator.settings.unit.shortLabel), \(coordinator.connectionState.spokenDescription)"
            : "Live reading unavailable, \(coordinator.connectionState.spokenDescription)")
    }

    private func applyWidth() {
        statusItem.length = StatusItemView.width(
            for: coordinator.settings.barLayout,
            showUnits: coordinator.settings.showUnits,
            unit: coordinator.settings.unit
        )
    }

    private func tooltip() -> String {
        var lines = ["Internet Speed Reader"]
        if let interface = coordinator.activeInterface {
            let kind = interface.kind == .tunnel ? "VPN tunnel payload" : interface.kind.rawValue
            lines.append("Live on \(interface.name) (\(kind)), all apps")
        }
        lines.append(coordinator.liveStatusText)
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
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
