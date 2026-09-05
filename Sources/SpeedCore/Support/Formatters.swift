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
    /// Below this the converted value has no meaningful two-decimal representation.
    /// Real traffic under it is shown as "<0.01", never as a bare zero: a moving link
    /// that reads 0.0 is indistinguishable from a dead app.
    static let displayFloor = 0.005

    /// Compact string for the menu bar. Precision follows the magnitude of the value in
    /// the unit actually shown, so megabytes per second keeps two decimals where megabits
    /// keeps one. The string never exceeds five characters, which is what pins the item
    /// width (ADR-019).
    public static func bar(_ mbps: Double, unit: SpeedUnit = .megabitsPerSecond, locale: Locale = .current) -> String {
        let value = convert(mbps, to: unit)
        let formatter = makeFormatter(locale: locale)

        // Not finite, negative, or an exact zero: the counters did not move. This is a
        // measured zero and is deliberately different from the unavailable dash.
        guard value.isFinite, value > 0 else {
            return fixed(0, digits: 2, formatter: formatter)
        }
        guard value >= displayFloor else {
            return "<" + fixed(0.01, digits: 2, formatter: formatter)
        }

        // Each band re-checks the band above it, so a value that rounds up to the band's
        // ceiling is formatted by the next rule instead of printing "1.00" or "100.0".
        if value < 1, rounded(value, digits: 2) < 1 {
            return fixed(value, digits: 2, formatter: formatter)
        }
        if value < 100, rounded(value, digits: 1) < 100 {
            return fixed(value, digits: 1, formatter: formatter)
        }
        if value < 1000, rounded(value, digits: 0) < 1000 {
            return fixed(value, digits: 0, formatter: formatter)
        }
        let giga = value / 1000
        // Above 10 Gbps a decimal would push the string past five characters.
        let digits = rounded(giga, digits: 1) < 10 ? 1 : 0
        return fixed(giga, digits: digits, formatter: formatter) + "G"
    }

    /// Fuller string for the panel, with more precision at low speeds.
    public static func panel(_ mbps: Double, unit: SpeedUnit = .megabitsPerSecond, locale: Locale = .current) -> String {
        let value = convert(mbps, to: unit)
        let formatter = makeFormatter(locale: locale)
        formatter.usesGroupingSeparator = true

        guard value.isFinite, value > 0 else { return fixed(0, digits: 2, formatter: formatter) }
        guard value >= displayFloor else { return "<" + fixed(0.01, digits: 2, formatter: formatter) }

        if value < 10, rounded(value, digits: 2) < 10 { return fixed(value, digits: 2, formatter: formatter) }
        if value < 100, rounded(value, digits: 1) < 100 { return fixed(value, digits: 1, formatter: formatter) }
        return fixed(value, digits: 0, formatter: formatter)
    }

    public static func convert(_ mbps: Double, to unit: SpeedUnit) -> Double {
        switch unit {
        case .megabitsPerSecond: return mbps
        case .megabytesPerSecond: return mbps / 8
        }
    }

    /// The strings the bar can draw at their widest, used to pin the status item width.
    /// Every band is represented, including the "<0.01" prefix and the giga suffix.
    public static func widestBarSamples(unit: SpeedUnit, locale: Locale = .current) -> [String] {
        [bar(0.0001, unit: unit, locale: locale),
         bar(convert(0.88, to: unit) * 8, unit: unit, locale: locale),
         bar(convert(88.88, to: unit) * 8, unit: unit, locale: locale),
         bar(convert(999.4, to: unit) * 8, unit: unit, locale: locale),
         bar(convert(9_999, to: unit) * 8, unit: unit, locale: locale),
         unavailable]
    }

    /// Shown when there is no trustworthy reading at all. Never used for measured zero.
    public static let unavailable = "—"

    private static func makeFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        // Half-up, not the default half-even: 84.25 reading as 84.2 looks like a bug
        // to anyone comparing the bar against the panel.
        formatter.roundingMode = .halfUp
        return formatter
    }

    private static func fixed(_ value: Double, digits: Int, formatter: NumberFormatter) -> String {
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private static func rounded(_ value: Double, digits: Int) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
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
