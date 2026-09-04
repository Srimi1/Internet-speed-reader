import Foundation
import IOKit.ps
import SpeedCore

/// Chooses the live-meter cadence from the power source.
///
/// App Nap throttles timers regardless of which API created them, so this is about
/// being a good citizen rather than about accuracy: every rate divides by measured
/// elapsed time, so a late tick still reports the correct number.
@MainActor
enum PowerPolicy {
    static func currentCadence() -> LiveThroughputMonitor.Cadence {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .seconds(5) }
        return isOnBattery() ? .seconds(2) : .seconds(1)
    }

    static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }
}
