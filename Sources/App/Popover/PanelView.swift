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
            testStatus
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
                    .disabled(!coordinator.canRunAppleTest)
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
        let unit = coordinator.settings.unit
        let readout = coordinator.liveReadout
        let label = readout.hasReading ? "Live · \(unit.shortLabel)" : "Unavailable"
        return HStack(spacing: 16) {
            liveTile(arrow: "arrow.down", value: readout.downMbps, label: label,
                     isActive: coordinator.downloadIsActive)
            liveTile(arrow: "arrow.up", value: readout.upMbps, label: label,
                     isActive: coordinator.uploadIsActive)
            Spacer()
            Sparkline(samples: coordinator.samples.elements.map(\.downMbps))
                .frame(width: 96, height: 30)
        }
    }

    private func liveTile(arrow: String, value: Double, label: String, isActive: Bool) -> some View {
        let readout = coordinator.liveReadout
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: arrow).font(.caption2)
                Text(readout.hasReading
                     ? SpeedCoreFormatter.panel(value, unit: coordinator.settings.unit)
                     : SpeedFormatter.unavailable)
                    .font(.system(size: 15, weight: isActive ? .semibold : .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .opacity(readout.freshness == .holding ? 0.55 : 1)
    }

    // MARK: Gauge and results

    private var gaugeSection: some View {
        HStack {
            Spacer()
            GaugeView(
                mbps: gaugeValue,
                unit: coordinator.settings.unit,
                isRunning: coordinator.speedTest.state.isRunning,
                phaseLabel: phaseLabel,
                canStart: coordinator.canRunSpeedTest,
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
        if coordinator.speedTest.state == .stopping { return "Stopping…" }
        if let engine = coordinator.speedTest.engineLabel, coordinator.speedTest.state.isRunning {
            return "\(engine) · \(phaseName)"
        }
        return phaseName
    }

    private var phaseName: String {
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
            scalarTile(isApple ? "BASE RTT" : "PING", value: result?.pingMs ?? result?.apple?.baseRttMs, caption: "ms")
            scalarTile(isApple ? "RPM" : "JITTER",
                       value: isApple ? (result?.apple?.downloadResponsivenessRPM ?? result?.apple?.responsivenessRPM) : result?.jitterMs,
                       caption: isApple ? "" : "ms")
            speedTile("DOWNLOAD", mbps: result?.downloadMbps)
            speedTile("UPLOAD", mbps: result?.uploadMbps)
        }
    }

    /// A measured speed, converted into the unit the user chose.
    private func speedTile(_ label: String, mbps: Double?) -> some View {
        let unit = coordinator.settings.unit
        return tile(label,
                    text: mbps.map { SpeedCoreFormatter.panel($0, unit: unit) } ?? SpeedFormatter.unavailable,
                    caption: unit.shortLabel)
    }

    /// A value that is not a speed. Never converted: a latency divided by eight is wrong.
    private func scalarTile(_ label: String, value: Double?, caption: String) -> some View {
        tile(label, text: value.map { SpeedCoreFormatter.scalar($0) } ?? SpeedFormatter.unavailable, caption: caption)
    }

    private func tile(_ label: String, text: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var testStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            if case let .failed(message) = coordinator.speedTest.state {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = coordinator.speedTestBlockedReason, !coordinator.speedTest.state.isRunning {
                Text(reason).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if coordinator.path.status != .satisfied {
                Text("Connect to a network to run a speed test.").foregroundStyle(.secondary)
            }
            if let result = coordinator.speedTest.latestResult {
                Text("Last test · \(Self.shortDate(result.startedAt)) · \(Self.provider(for: result))")
                    .foregroundStyle(.secondary)
                if let fallback = result.fallbackFrom, !fallback.isEmpty {
                    let names = fallback.compactMap { SpeedTestEngineKey(rawValue: $0)?.displayName }
                    Text("after \(names.joined(separator: ", ")) refused")
                        .foregroundStyle(.secondary)
                }
                if result.methodologyVersion == nil {
                    Text("Earlier measurement method")
                        .foregroundStyle(.secondary)
                } else if result.engine == .cloudflare {
                    Text("Download: \(Self.qualityLabel(result.downloadQuality)) · Upload: \(Self.qualityLabel(result.uploadQuality))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2)
    }

    /// Names the engine that actually produced a result, including which Cloudflare host.
    private static func provider(for result: SpeedTestResult) -> String {
        if let key = result.engineKey.flatMap(SpeedTestEngineKey.init(rawValue:)) {
            return key.displayName
        }
        return result.engine == .cloudflare ? "Cloudflare" : "Apple"
    }

    private static func qualityLabel(_ quality: String?) -> String {
        switch quality {
        case "good": return "validated"
        case "shortSample": return "short sample"
        case "dataLimited": return "data limit reached"
        case "incomplete": return "limited · unfinished transfers excluded"
        case "variable": return "variable"
        default: return "quality unavailable"
        }
    }

    private var serverRow: some View {
        Group {
            if let result = coordinator.speedTest.latestResult {
                Text([result.ispName, result.serverName].compactMap { $0 }.joined(separator: " · "))
            } else if !coordinator.speedTest.state.isRunning {
                Text("Press GO to measure download and upload capacity")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(Self.shortDate(result.startedAt))
                            .frame(width: 84, alignment: .leading)
                        Text("↓ \(Self.historySpeed(result.downloadMbps, unit: coordinator.settings.unit))")
                        Text("↑ \(Self.historySpeed(result.uploadMbps, unit: coordinator.settings.unit))")
                        Text(coordinator.settings.unit.shortLabel).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    let engine = Self.provider(for: result)
                    Text(result.methodologyVersion == nil ? "\(engine) · earlier measurement method" : engine)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
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
        Text("The menu bar shows current traffic for all apps, including protocol overhead. GO measures capacity to the test server. Idle traffic can be zero.")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func historySpeed(_ mbps: Double?, unit: SpeedUnit) -> String {
        mbps.map { SpeedCoreFormatter.panel($0, unit: unit) } ?? SpeedFormatter.unavailable
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
