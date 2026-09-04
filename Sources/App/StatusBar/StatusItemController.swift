import AppKit
import SpeedCore

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

    private func refresh() {
        readout.model = StatusItemRenderModel(
            downText: SpeedFormatter.bar(coordinator.downMbps, unit: coordinator.unit),
            upText: SpeedFormatter.bar(coordinator.upMbps, unit: coordinator.unit),
            state: coordinator.connectionState,
            layout: coordinator.barLayout,
            showUnits: coordinator.showUnitsInBar,
            unit: coordinator.unit
        )
        statusItem.button?.toolTip = tooltip()
    }

    private func applyWidth() {
        statusItem.length = StatusItemView.width(
            for: coordinator.barLayout,
            showUnits: coordinator.showUnitsInBar,
            unit: coordinator.unit
        )
    }

    private func tooltip() -> String {
        var lines = ["Internet Speed Reader"]
        if let interface = coordinator.activeInterface {
            let kind = interface.kind == .tunnel ? "VPN tunnel payload" : interface.kind.rawValue
            lines.append("Live on \(interface.name) (\(kind)), all apps")
        }
        lines.append("Link-layer throughput, about 10 percent above payload")
        return lines.joined(separator: "\n")
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            showContextMenu()
        } else {
            // Left click currently shows the same menu; the popover arrives in M6.
            showContextMenu()
        }
    }

    private func showContextMenu() {
        coordinator.loginItem.refresh()

        let menu = NSMenu()
        menu.delegate = self

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
}
