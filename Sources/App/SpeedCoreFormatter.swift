import SpeedCore

/// Thin naming shim so views read cleanly.
///
/// Every speed goes through a call that takes an explicit unit: v1 dropped the unit here,
/// so the panel always showed megabits while the menu bar honoured the preference, and the
/// two disagreed by a factor of eight with nothing on screen to say which was which.
enum SpeedCoreFormatter {
    /// Formats a speed in megabits per second into the unit the user chose.
    static func panel(_ mbps: Double, unit: SpeedUnit) -> String { SpeedFormatter.panel(mbps, unit: unit) }
    /// Formats a value that is NOT a speed (milliseconds, round trips per minute). Never
    /// converted, because dividing a latency by eight is meaningless.
    static func scalar(_ value: Double) -> String { SpeedFormatter.panel(value, unit: .megabitsPerSecond) }
    static func bar(_ value: Double, unit: SpeedUnit) -> String { SpeedFormatter.bar(value, unit: unit) }
}
