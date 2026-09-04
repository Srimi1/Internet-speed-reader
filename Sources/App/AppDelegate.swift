import AppKit
import SpeedCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement: no Dock icon, no app menu bar.
        NSApp.setActivationPolicy(.accessory)

        statusItemController = StatusItemController(coordinator: coordinator)
        coordinator.start()

        Log.app.info("Internet Speed Reader launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
