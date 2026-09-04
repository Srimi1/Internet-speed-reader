import Foundation
import ServiceManagement
import SpeedCore

/// Launch-at-login via SMAppService.
///
/// The service must be code signed, and the background task database records the app's
/// path, so registration only makes sense from /Applications. If the app is later moved
/// or deleted, status flips to .notFound and the toggle silently stops working.
@MainActor
final class LoginItemManager {
    enum State: Equatable {
        case enabled
        case disabled
        /// The user must approve (or re-approve) in System Settings.
        case requiresApproval
        /// Registered against a path that no longer exists.
        case notFound

        var isOn: Bool { self == .enabled }
    }

    private(set) var state: State = .disabled
    private(set) var lastError: String?

    func refresh() {
        state = Self.map(SMAppService.mainApp.status)
    }

    private static func map(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    /// True if the requested state was reached.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            Log.app.info("login item set to \(enabled, privacy: .public), state=\(String(describing: self.state), privacy: .public)")
            return true
        } catch let error as NSError {
            // Already registered is success, not a failure.
            if error.code == kSMErrorAlreadyRegistered {
                refresh()
                return true
            }
            lastError = error.localizedDescription
            refresh()
            Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when the app is running from /Applications, where registration is durable.
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
