import Foundation

/// What the menu bar item draws.
///
/// Lives in SpeedCore rather than the app target so its default and its migration are
/// covered by the library-only test bundle. Raw values are the stored UserDefaults
/// strings and must never change.
public enum BarLayout: String, CaseIterable, Codable, Sendable {
    /// Download and upload, stacked. The default: both directions are always readable.
    case twoLine
    /// Download and upload on one row.
    case oneLine
    /// One number that follows the traffic, hiding the other direction.
    case adaptive
    case dotOnly

    /// Missing or unrecognised preferences resolve to the both-directions layout.
    /// A stored `adaptive` is honoured here; the one-time 2.0 migration that moves an
    /// existing `adaptive` preference to `twoLine` lives in AppSettings, guarded by its
    /// own flag, so a deliberate 2.0 re-selection of `adaptive` sticks.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .twoLine
    }

    public var title: String {
        switch self {
        case .twoLine: return "Download and upload, two lines"
        case .oneLine: return "Download and upload, one line"
        case .adaptive: return "One number, hides the other direction"
        case .dotOnly: return "Dot only"
        }
    }

    /// True when the layout draws both directions at once.
    public var showsBothDirections: Bool { self == .twoLine || self == .oneLine }
}
