import Foundation
import IOKit.ps
import SpeedCore

@MainActor
enum PowerPolicy {
    static func currentInterval(policy: LiveRefreshPolicy) -> Double {
        policy.interval(isOnBattery: isOnBattery(), isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
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

/// Power-source and Low Power Mode changes are separate system events.
@MainActor
final class PowerPolicyObserver {
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard source == nil, observer == nil else { return }
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let owner = Unmanaged<PowerPolicyObserver>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.onChange() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange() }
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
