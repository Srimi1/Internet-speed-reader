import SpeedCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "bell") }
            SpeedTestSettings().tabItem { Label("Speed Test", systemImage: "speedometer") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
        }
        .environment(coordinator)
        .frame(width: 460, height: 300)
    }
}

private struct GeneralSettings: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { coordinator.loginItem.state.isOn },
                set: { _ in coordinator.toggleLoginItem() }
            ))
            if let error = coordinator.loginItem.lastError {
                Text("Launch at login: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if coordinator.loginItem.state == .requiresApproval {
                HStack {
                    Text("Approval is needed in System Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { coordinator.loginItem.openSystemSettings() }
                }
            }
            if !LoginItemManager.isInApplicationsFolder {
                Text("Move the app to /Applications so the login item survives updates.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Menu bar shows", selection: $settings.barLayout) {
                ForEach(BarLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Two lines keeps download and upload readable at the same time. The active direction is drawn in bold.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Units", selection: $settings.unit) {
                Text("Megabits (Mbps)").tag(SpeedUnit.megabitsPerSecond)
                Text("Megabytes (MB/s)").tag(SpeedUnit.megabytesPerSecond)
            }
            Toggle("Show units in the menu bar", isOn: $settings.showUnits)
            Picker("Refresh", selection: $settings.refreshPolicy) {
                ForEach(AppSettings.RefreshPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettings: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        Form {
            Toggle("Notify when the internet drops", isOn: $settings.notifyOnDrop)
            Toggle("Notify when it comes back", isOn: $settings.notifyOnRestore)

            LabeledContent("Notify after") {
                Stepper("\(Int(settings.notifyAfterSeconds)) seconds", value: $settings.notifyAfterSeconds, in: 5...60, step: 5)
            }
            LabeledContent("Log outages longer than") {
                Stepper("\(Int(settings.minimumOutageSeconds)) seconds", value: $settings.minimumOutageSeconds, in: 1...30)
            }

            LabeledContent("Permission") {
                HStack {
                    Text(coordinator.notificationStatusText)
                    if coordinator.notificationStatusText != "Allowed" {
                        Button("Open Notification Settings") { coordinator.openNotificationSettings() }
                    }
                }
            }

            Text("Focus modes can hide banners. The menu bar turning red is the signal that always shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SpeedTestSettings: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        Form {
            Picker("Engine", selection: $settings.speedTestEngine) {
                ForEach(SpeedTestEngineChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Automatic tries Cloudflare first and falls back to the alternatives if a server refuses. Apple's tool picks its own endpoint, which can be far away, so its numbers are a second opinion.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Download streams") {
                Stepper("\(settings.downloadStreams)", value: $settings.downloadStreams, in: 2...8)
            }
            LabeledContent("Upload streams") {
                Stepper("\(settings.uploadStreams)", value: $settings.uploadStreams, in: 1...6)
            }
            LabeledContent("Phase duration") {
                Stepper("\(Int(settings.phaseSeconds)) seconds", value: $settings.phaseSeconds, in: 5...15, step: 5)
            }
            Toggle("Data saver (shorter phases, smaller ceilings)", isOn: $settings.dataSaver)
            Toggle("Ask before testing on metered or low power", isOn: $settings.confirmOnMetered)
            LabeledContent("Apple deep test limit") {
                Stepper("\(settings.appleMaxSeconds) seconds", value: $settings.appleMaxSeconds, in: 10...30, step: 5)
            }
            Toggle("Reopen the panel when a test finishes", isOn: $settings.reopenPanelOnFinish)

            Text(coordinator.dataEstimateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Form {
            LabeledContent("Active interface") {
                Text(coordinator.activeInterface.map { "\($0.name) (\($0.kind.rawValue))" } ?? "none")
            }
            LabeledContent("Path status") { Text(coordinator.path.status.rawValue) }
            LabeledContent("Expensive") { Text(coordinator.path.isExpensive ? "yes" : "no") }
            LabeledContent("Constrained") { Text(coordinator.path.isConstrained ? "yes" : "no") }

            Text("Speed tests always follow the system's default route. The live meter reads the interface above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Clear outage log") { coordinator.clearOutages() }
                Button("Clear test history") { coordinator.clearHistory() }
            }
        }
        .formStyle(.grouped)
    }
}
