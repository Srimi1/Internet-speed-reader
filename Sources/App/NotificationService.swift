import Foundation
import SpeedCore
import UserNotifications

/// Wraps UNUserNotificationCenter for outage banners.
///
/// Two hard requirements learned from the platform, both load-bearing:
/// 1. This only works from a real .app bundle. From a bare binary (`swift run`) the
///    center throws NSInternalInconsistencyException, which cannot be caught with `try`.
/// 2. The delegate must be set before applicationDidFinishLaunching returns, or a
///    notification that launched the app never reaches didReceive.
@MainActor
final class NotificationService: NSObject {
    enum Identifier {
        static let down = "isr.outage.down"
        static let up = "isr.outage.up"
    }

    enum Category {
        static let outage = "OUTAGE"
        static let runTest = "RUN_TEST"
        static let showLog = "SHOW_LOG"
    }

    private let center = UNUserNotificationCenter.current()
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Called when the user taps "Run Speed Test" on an outage banner.
    var onRunTestRequested: (() -> Void)?
    /// Called when the user taps "Show Outage Log".
    var onShowLogRequested: (() -> Void)?

    func bootstrap() {
        center.delegate = self
        registerCategories()
        Task { await refreshAuthorizationStatus() }
    }

    private func registerCategories() {
        let runTest = UNNotificationAction(
            identifier: Category.runTest,
            title: "Run Speed Test",
            options: [.foreground]
        )
        let showLog = UNNotificationAction(
            identifier: Category.showLog,
            title: "Show Outage Log",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Category.outage,
            actions: [runTest, showLog],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            // Alert only. Never .sound (the user asked for silent alerts) and never
            // .criticalAlert, which needs an Apple-granted entitlement and can fail
            // the whole request.
            let granted = try await center.requestAuthorization(options: [.alert])
            await refreshAuthorizationStatus()
            Log.app.info("notification authorization granted=\(granted, privacy: .public)")
            return granted
        } catch {
            Log.app.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorizationStatus()
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Posts immediately (nil trigger). Returns false if the post failed.
    @discardableResult
    func post(
        identifier: String,
        title: String,
        body: String,
        replacing: [String] = []
    ) async -> Bool {
        if !replacing.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: replacing)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.categoryIdentifier = Category.outage
        content.interruptionLevel = .active

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            Log.app.error("failed to post notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show even when our own app is frontmost. .alert is deprecated since macOS 11.
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Category.runTest:
                self.onRunTestRequested?()
            case Category.showLog, UNNotificationDefaultActionIdentifier:
                self.onShowLogRequested?()
            default:
                break
            }
        }
    }
}
