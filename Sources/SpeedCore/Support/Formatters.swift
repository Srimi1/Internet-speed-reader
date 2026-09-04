import Foundation

public enum SpeedUnit: String, Sendable, Codable, CaseIterable {
    case megabitsPerSecond
    case megabytesPerSecond

    public var shortLabel: String {
        switch self {
        case .megabitsPerSecond: return "Mbps"
        case .megabytesPerSecond: return "MB/s"
        }
    }
}

public enum SpeedFormatter {
    /// Compact string for the menu bar. Keeps the character count small and predictable
    /// so the item's fixed width holds from 0 to gigabit speeds.
    public static func bar(_ mbps: Double, unit: SpeedUnit = .megabitsPerSecond, locale: Locale = .current) -> String {
        let value = convert(mbps, to: unit)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        // Half-up, not the default half-even: 84.25 reading as 84.2 looks like a bug
        // to anyone comparing the bar against the panel.
        formatter.roundingMode = .halfUp

        switch value {
        case ..<0.05:
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return formatter.string(from: 0) ?? "0.0"
        case ..<100:
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return formatter.string(from: NSNumber(value: value)) ?? "0.0"
        case ..<1000:
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value)) ?? "0"
        default:
            // Above 10 Gbps a decimal would push the string to six characters and
            // break the fixed item width, so drop it.
            let giga = value / 1000
            let decimals = giga < 10 ? 1 : 0
            formatter.minimumFractionDigits = decimals
            formatter.maximumFractionDigits = decimals
            return (formatter.string(from: NSNumber(value: giga)) ?? "1.0") + "G"
        }
    }

    /// Fuller string for the panel, with more precision at low speeds.
    public static func panel(_ mbps: Double, unit: SpeedUnit = .megabitsPerSecond, locale: Locale = .current) -> String {
        let value = convert(mbps, to: unit)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : (value < 100 ? 1 : 0)
        formatter.minimumFractionDigits = value < 100 ? 1 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    public static func convert(_ mbps: Double, to unit: SpeedUnit) -> Double {
        switch unit {
        case .megabitsPerSecond: return mbps
        case .megabytesPerSecond: return mbps / 8
        }
    }

    /// The widest strings the bar can ever draw, used to pin the status item width.
    public static func widestBarSamples(unit: SpeedUnit, locale: Locale = .current) -> [String] {
        [bar(999.4, unit: unit, locale: locale),
         bar(9_999, unit: unit, locale: locale),
         bar(88.88, unit: unit, locale: locale)]
    }
}

public enum DurationFormatter {
    /// "4m 12s", "1h 03m", "8s" — for outage durations a human reads at a glance.
    public static func humanReadable(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            return "\(total / 60)m \(String(format: "%02d", total % 60))s"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return "\(hours)h \(String(format: "%02d", minutes))m"
    }
}
