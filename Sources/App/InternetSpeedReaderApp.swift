import SwiftUI

@main
struct InternetSpeedReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The only SwiftUI scene. The menu bar item and panel are AppKit, built by AppDelegate.
        Settings {
            SettingsView()
                .environment(appDelegate.coordinator)
        }
    }
}
