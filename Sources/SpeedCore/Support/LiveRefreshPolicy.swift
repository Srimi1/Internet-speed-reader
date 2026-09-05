import Foundation

public enum LiveRefreshPolicy: String, CaseIterable, Sendable {
    case always, reduceOnBattery

    /// The old panel-only setting was never implemented. Migrate it, and unset
    /// preferences, to continuous sampling while preserving an explicit battery choice.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .always
    }

    public var title: String {
        switch self {
        case .always: return "Always 1 second"
        case .reduceOnBattery: return "Reduce on battery"
        }
    }

    public func interval(isOnBattery: Bool, isLowPowerMode: Bool) -> Double {
        guard self == .reduceOnBattery else { return 1 }
        return isLowPowerMode ? 5 : (isOnBattery ? 2 : 1)
    }
}
