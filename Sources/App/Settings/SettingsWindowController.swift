import AppKit
import SwiftUI

/// A retained AppKit window makes Settings reachable from both native menus before
/// any SwiftUI popover exists. The old showSettingsWindow: action has no target on
/// current macOS and silently did nothing.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Internet Speed Reader Settings"
        window.identifier = NSUserInterfaceItemIdentifier("internet-speed-reader.settings")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = NSHostingController(
            rootView: SettingsView().environment(coordinator)
        )
        let autosaveName = "InternetSpeedReader.Settings"
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { return nil }

    func show() {
        guard let window else { return }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
