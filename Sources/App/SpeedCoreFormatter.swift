import SpeedCore

/// Thin naming shim so views read cleanly.
enum SpeedCoreFormatter {
    static func panel(_ value: Double) -> String { SpeedFormatter.panel(value) }
    static func bar(_ value: Double, unit: SpeedUnit) -> String { SpeedFormatter.bar(value, unit: unit) }
}
