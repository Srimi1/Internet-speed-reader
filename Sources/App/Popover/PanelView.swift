import SpeedCore
import SwiftUI

struct PanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var tab: Tab = .history

    enum Tab: String, CaseIterable, Identifiable {
        case history = "History"
        case outages = "Outages"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            liveSection
            gaugeSection
            resultTiles
            serverRow
            Divider()
            tabs
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(coordinator.connectionState.dotColor))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = statusSubtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("Check Connection Now") { coordinator.checkConnectionNow() }
                Button("Apple Deep Test") { coordinator.startAppleDeepTest() }
                Divider()
                Button("Settings…") { coordinator.openSettings() }
                Button("Quit Internet Speed Reader") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    private var statusTitle: String {
        switch coordinator.connectionState {
        case .online: return "Internet is up"
        case .offline: return "Internet is down"
        case .captivePortal: return "Sign-in required"
        case .suspect: return "Checking connection"
        case .testing: return "Running a speed test"
        case .unknown: return "Checking connection"
        }
    }

    private var statusSubtitle: String? {
        if coordinator.connectionState == .captivePortal {
            return "This network wants you to sign in first"
        }
        if let outage = coordinator.outages.first, outage.isOpen {
            return "Down for \(DurationFormatter.humanReadable(outage.duration()))"
        }
        if let interface = coordinator.activeInterface {
            return interface.kind == .tunnel
                ? "VPN (\(interface.name)) · tunnel payload"
                : "\(interface.kind == .wifi ? "Wi-Fi" : "Ethernet") · \(interface.name)"
        }
        return nil
    }

    // MARK: Live

    private var liveSection: some View {
        HStack(spacing: 16) {
            liveTile(arrow: "arrow.down", value: coordinator.downMbps, label: "Now")
            liveTile(arrow: "arrow.up", value: coordinator.upMbps, label: "Now")
            Spacer()
            Sparkline(samples: coordinator.samples.elements.map(\.downMbps))
                .frame(width: 96, height: 30)
        }
    }

    private func liveTile(arrow: String, value: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: arrow).font(.caption2)
                Text(SpeedCoreFormatter.panel(value))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Gauge and results

    private var gaugeSection: some View {
        HStack {
            Spacer()
            GaugeView(
                mbps: gaugeValue,
                isRunning: coordinator.speedTest.state.isRunning,
                phaseLabel: phaseLabel,
                canStart: coordinator.speedTest.canStart,
                onStart: { coordinator.startSpeedTest() },
                onStop: { coordinator.speedTest.cancel() }
            )
            Spacer()
        }
    }

    private var gaugeValue: Double {
        coordinator.speedTest.state.isRunning
            ? coordinator.speedTest.liveMbps
            : (coordinator.speedTest.latestResult?.downloadMbps ?? 0)
    }

    private var phaseLabel: String {
        switch coordinator.speedTest.phase {
        case .meta: return "Finding server"
        case .latency: return "Latency"
        case .downloadProbe, .download: return "Download"
        case .uploadProbe, .upload: return "Upload"
        case .finishing: return "Finishing"
        case .idle: return ""
        }
    }

    private var resultTiles: some View {
        let result = coordinator.speedTest.latestResult
        let isApple = result?.engine == .appleNetworkQuality

        return HStack(spacing: 0) {
            tile(isApple ? "BASE RTT" : "PING", value: result?.pingMs ?? result?.apple?.baseRttMs, unit: "ms")
            tile(isApple ? "RPM" : "JITTER",
                 value: isApple ? (result?.apple?.downloadResponsivenessRPM ?? result?.apple?.responsivenessRPM) : result?.jitterMs,
                 unit: isApple ? "" : "ms")
            tile("DOWNLOAD", value: result?.downloadMbps, unit: "Mbps")
            tile("UPLOAD", value: result?.uploadMbps, unit: "Mbps")
        }
    }

    private func tile(_ label: String, value: Double?, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value.map { SpeedCoreFormatter.panel($0) } ?? "—")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var serverRow: some View {
        HStack {
            if let result = coordinator.speedTest.latestResult {
                Text([result.ispName, result.clientLocation].compactMap { $0 }.joined(separator: " · "))
                Spacer()
                Text(result.serverName ?? "")
            } else if case let .failed(message) = coordinator.speedTest.state {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Press GO to measure your connection")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Tabs

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    switch tab {
                    case .history: historyRows
                    case .outages: outageRows
                    }
                }
            }
            .frame(height: 96)
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        if coordinator.speedTest.history.isEmpty {
            Text("No tests yet").font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(coordinator.speedTest.history.prefix(20)) { result in
                HStack {
                    Text(Self.shortDate(result.startedAt))
                        .frame(width: 84, alignment: .leading)
                    Text("↓ \(SpeedCoreFormatter.panel(result.downloadMbps ?? 0))")
                    Text("↑ \(SpeedCoreFormatter.panel(result.uploadMbps ?? 0))")
                    Spacer()
                    if result.engine == .appleNetworkQuality {
                        Text("Apple").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var outageRows: some View {
        if coordinator.outages.isEmpty {
            Text("No outages recorded").font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(coordinator.outages.prefix(30)) { outage in
                HStack {
                    Text(Self.shortDate(outage.start))
                        .frame(width: 84, alignment: .leading)
                    Text(outage.isOpen ? "ongoing" : DurationFormatter.humanReadable(outage.duration()))
                    Spacer()
                    Text(outage.unsatisfiedReason ?? outage.cause.rawValue)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .font(.caption2)
                .monospacedDigit()
            }
        }
    }

    private var footer: some View {
        Text("Menu bar shows live link throughput for all apps. Test results measure payload only, so they read a little lower.")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}

/// Minimal line chart of recent samples.
struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let peak = max(samples.max() ?? 1, 0.1)
            var path = Path()
            for (index, value) in samples.enumerated() {
                let x = size.width * Double(index) / Double(samples.count - 1)
                let y = size.height * (1 - value / peak)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.4)
        }
        .accessibilityHidden(true)
    }
}
