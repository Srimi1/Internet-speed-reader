import Foundation
import Observation
import SpeedCore

/// User preferences, backed by UserDefaults and keyed off the bundle identifier,
/// which never changes for exactly this reason.
@Observable
@MainActor
final class AppSettings {
    enum Key: String {
        case barLayout, barLayoutMigratedV2, unit, showUnits, refreshPolicy
        case notifyOnDrop, notifyOnRestore, notifyAfterSeconds, minimumOutageSeconds
        case downloadStreams, uploadStreams, phaseSeconds, dataSaver, confirmOnMetered, speedTestEngine
        case appleMaxSeconds, reopenPanelOnFinish
        case launchAtLoginWanted
    }

    typealias RefreshPolicy = LiveRefreshPolicy

    private let defaults: UserDefaults

    var barLayout: BarLayout { didSet { set(barLayout.rawValue, .barLayout) } }
    var unit: SpeedUnit { didSet { set(unit.rawValue, .unit) } }
    var showUnits: Bool { didSet { set(showUnits, .showUnits) } }
    @ObservationIgnored var onRefreshPolicyChange: (() -> Void)?
    var refreshPolicy: RefreshPolicy {
        didSet {
            set(refreshPolicy.rawValue, .refreshPolicy)
            onRefreshPolicyChange?()
        }
    }

    var notifyOnDrop: Bool { didSet { set(notifyOnDrop, .notifyOnDrop) } }
    var notifyOnRestore: Bool { didSet { set(notifyOnRestore, .notifyOnRestore) } }
    var notifyAfterSeconds: Double { didSet { set(notifyAfterSeconds, .notifyAfterSeconds) } }
    var minimumOutageSeconds: Double { didSet { set(minimumOutageSeconds, .minimumOutageSeconds) } }

    var downloadStreams: Int { didSet { set(downloadStreams, .downloadStreams) } }
    var uploadStreams: Int { didSet { set(uploadStreams, .uploadStreams) } }
    var phaseSeconds: Double { didSet { set(phaseSeconds, .phaseSeconds) } }
    var dataSaver: Bool { didSet { set(dataSaver, .dataSaver) } }
    var confirmOnMetered: Bool { didSet { set(confirmOnMetered, .confirmOnMetered) } }
    /// Which measurement service GO uses. Automatic tries each in turn.
    var speedTestEngine: SpeedTestEngineChoice { didSet { set(speedTestEngine.rawValue, .speedTestEngine) } }
    var appleMaxSeconds: Int { didSet { set(appleMaxSeconds, .appleMaxSeconds) } }
    var reopenPanelOnFinish: Bool { didSet { set(reopenPanelOnFinish, .reopenPanelOnFinish) } }
    /// The user's intent, separate from what the system currently has registered. On by
    /// default because the app is meant to just be there; the system registration is
    /// re-applied on every launch because reinstalling the bundle silently invalidates it.
    var launchAtLoginWanted: Bool { didSet { set(launchAtLoginWanted, .launchAtLoginWanted) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 2.0 shows both directions by default. A 1.x preference of the single-number
        // layout is moved across once, because it was the old default rather than a
        // deliberate choice for most people; the flag lets a 2.0 re-selection stick.
        let storedLayout = defaults.string(forKey: Key.barLayout.rawValue)
        let migratedLayout = defaults.object(forKey: Key.barLayoutMigratedV2.rawValue) as? Bool ?? false
        if !migratedLayout, storedLayout == BarLayout.adaptive.rawValue {
            barLayout = .twoLine
        } else {
            barLayout = BarLayout(storedValue: storedLayout)
        }
        defaults.set(true, forKey: Key.barLayoutMigratedV2.rawValue)
        unit = SpeedUnit(rawValue: defaults.string(forKey: Key.unit.rawValue) ?? "") ?? .megabitsPerSecond
        showUnits = defaults.object(forKey: Key.showUnits.rawValue) as? Bool ?? false
        refreshPolicy = RefreshPolicy(storedValue: defaults.string(forKey: Key.refreshPolicy.rawValue))
        notifyOnDrop = defaults.object(forKey: Key.notifyOnDrop.rawValue) as? Bool ?? true
        notifyOnRestore = defaults.object(forKey: Key.notifyOnRestore.rawValue) as? Bool ?? true
        notifyAfterSeconds = defaults.object(forKey: Key.notifyAfterSeconds.rawValue) as? Double ?? 10
        minimumOutageSeconds = defaults.object(forKey: Key.minimumOutageSeconds.rawValue) as? Double ?? 3
        downloadStreams = defaults.object(forKey: Key.downloadStreams.rawValue) as? Int ?? 6
        uploadStreams = defaults.object(forKey: Key.uploadStreams.rawValue) as? Int ?? 4
        phaseSeconds = defaults.object(forKey: Key.phaseSeconds.rawValue) as? Double ?? 10
        dataSaver = defaults.object(forKey: Key.dataSaver.rawValue) as? Bool ?? false
        confirmOnMetered = defaults.object(forKey: Key.confirmOnMetered.rawValue) as? Bool ?? true
        speedTestEngine = SpeedTestEngineChoice(storedValue: defaults.string(forKey: Key.speedTestEngine.rawValue))
        appleMaxSeconds = defaults.object(forKey: Key.appleMaxSeconds.rawValue) as? Int ?? 15
        reopenPanelOnFinish = defaults.object(forKey: Key.reopenPanelOnFinish.rawValue) as? Bool ?? true
        launchAtLoginWanted = defaults.object(forKey: Key.launchAtLoginWanted.rawValue) as? Bool ?? true
        defaults.set(refreshPolicy.rawValue, forKey: Key.refreshPolicy.rawValue)
        defaults.set(barLayout.rawValue, forKey: Key.barLayout.rawValue)
        defaults.set(speedTestEngine.rawValue, forKey: Key.speedTestEngine.rawValue)
    }

    private func set(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    var speedTestOptions: SpeedTestOptions {
        var options = dataSaver ? SpeedTestOptions.dataSaver : SpeedTestOptions()
        options.downloadStreams = downloadStreams
        options.uploadStreams = uploadStreams
        if !dataSaver {
            options.downloadSeconds = phaseSeconds
            options.uploadSeconds = max(4, phaseSeconds - 2)
        }
        return options
    }

    /// Everything one run needs, composed from the stored preferences.
    func speedTestRequest(interfaceName: String?, trigger: String = "manual") -> SpeedTestRequest {
        SpeedTestRequest(
            interfaceName: interfaceName,
            cloudflareOptions: speedTestOptions,
            appleMaxSeconds: appleMaxSeconds,
            trigger: trigger
        )
    }

    /// Rough data cost of one test, so the estimate in Settings is honest.
    func estimatedBytesPerTest(downMbps: Double, upMbps: Double) -> Double {
        let options = speedTestOptions
        return (downMbps * options.downloadSeconds + upMbps * options.uploadSeconds) * 1e6 / 8
    }
}
