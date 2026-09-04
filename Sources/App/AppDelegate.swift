import AppKit
import SpeedCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleCommandLineFlags() { return }

        // Belt and braces alongside LSUIElement: no Dock icon, no app menu bar.
        NSApp.setActivationPolicy(.accessory)

        statusItemController = StatusItemController(coordinator: coordinator)
        coordinator.start()

        Log.app.info("Internet Speed Reader launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    /// Maintenance entry points, run as
    /// `/Applications/InternetSpeedReader.app/Contents/MacOS/InternetSpeedReader --flag`.
    /// They must run from inside the bundle because SMAppService keys off it.
    private func handleCommandLineFlags() -> Bool {
        let arguments = CommandLine.arguments.dropFirst()
        guard let flag = arguments.first(where: { $0.hasPrefix("--") }) else { return false }

        let manager = LoginItemManager()
        manager.refresh()

        switch flag {
        case "--login-status":
            print("login item: \(manager.state)")
            print("bundle: \(Bundle.main.bundlePath)")
        case "--unregister-login-item":
            let ok = manager.setEnabled(false)
            print(ok ? "login item unregistered" : "failed: \(manager.lastError ?? "unknown")")
        case "--register-login-item":
            let ok = manager.setEnabled(true)
            print(ok ? "login item registered: \(manager.state)" : "failed: \(manager.lastError ?? "unknown")")
        default:
            print("unknown flag \(flag)")
        }
        exit(0)
    }
}
