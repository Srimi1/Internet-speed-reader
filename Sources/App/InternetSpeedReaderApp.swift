import SwiftUI

@main
struct InternetSpeedReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep the Settings scene as the SwiftUI app scene, but route its command
        // through the same retained native window used by the menu bar and panel.
        Settings {
            SettingsView()
                .environment(appDelegate.coordinator)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.coordinator.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
