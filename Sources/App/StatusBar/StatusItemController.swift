import AppKit
import SpeedCore

/// Owns the NSStatusItem, its custom view, and click routing.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: 64)
        super.init()

        statusItem.autosaveName = "com.srimi.internetspeedreader.readout"
        if let button = statusItem.button {
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Internet speed")
        }
    }

    @objc private func handleClick() {
        Log.app.debug("status item clicked")
    }
}
