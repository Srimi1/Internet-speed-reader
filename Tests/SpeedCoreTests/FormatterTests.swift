import Foundation
import Testing
@testable import SpeedCore

@Suite("Formatters")
struct FormatterTests {
    let en = Locale(identifier: "en_US")

    @Test("Bar strings stay compact across every magnitude")
    func barMagnitudes() {
        #expect(SpeedFormatter.bar(0, locale: en) == "0.00")
        #expect(SpeedFormatter.bar(0.02, locale: en) == "0.02")
        #expect(SpeedFormatter.bar(8.44, locale: en) == "8.4")
        #expect(SpeedFormatter.bar(84.25, locale: en) == "84.3")
        #expect(SpeedFormatter.bar(512.7, locale: en) == "513")
        #expect(SpeedFormatter.bar(1_240, locale: en) == "1.2G")
        #expect(SpeedFormatter.bar(12_400, locale: en) == "12G")
    }

    /// The v1 rule printed one decimal at every magnitude, so ordinary traffic read "0.0"
    /// and the app looked dead while it was measuring correctly.
    @Test("Small but real traffic never reads as a bare zero")
    func barSmallValues() {
        #expect(SpeedFormatter.bar(0.003, locale: en) == "<0.01")
        #expect(SpeedFormatter.bar(0.04, locale: en) == "0.04")
        #expect(SpeedFormatter.bar(0.15, locale: en) == "0.15")
        #expect(SpeedFormatter.bar(0.62, locale: en) == "0.62")
        #expect(SpeedFormatter.bar(5.3, locale: en) == "5.3")
    }

    @Test("An exact zero is a measured zero, not an unavailable reading")
    func barZeroIsDistinctFromUnavailable() {
        #expect(SpeedFormatter.bar(0, locale: en) == "0.00")
        #expect(SpeedFormatter.bar(-1, locale: en) == "0.00")
        #expect(SpeedFormatter.bar(.nan, locale: en) == "0.00")
        #expect(SpeedFormatter.unavailable == "—")
    }

    /// Every band re-checks the band above it, so rounding up never prints a string that
    /// belongs to the next band ("1.00", "100.0", "1000").
    @Test("Values that round up move into the next band")
    func barBandBoundaries() {
        #expect(SpeedFormatter.bar(0.996, locale: en) == "1.0")
        #expect(SpeedFormatter.bar(99.96, locale: en) == "100")
        #expect(SpeedFormatter.bar(999.5, locale: en) == "1.0G")
        #expect(SpeedFormatter.bar(9_999, locale: en) == "10G")
    }

    @Test("Megabytes per second divides by eight and keeps its precision")
    func megabytes() {
        #expect(SpeedFormatter.bar(80, unit: .megabytesPerSecond, locale: en) == "10.0")
        #expect(SpeedFormatter.bar(0.03, unit: .megabytesPerSecond, locale: en) == "<0.01")
        #expect(SpeedFormatter.bar(0.04, unit: .megabytesPerSecond, locale: en) == "0.01")
        #expect(SpeedFormatter.bar(0.15, unit: .megabytesPerSecond, locale: en) == "0.02")
        #expect(SpeedFormatter.bar(5.3, unit: .megabytesPerSecond, locale: en) == "0.66")
        #expect(SpeedFormatter.bar(6, unit: .megabytesPerSecond, locale: en) == "0.75")
        #expect(SpeedFormatter.bar(125, unit: .megabytesPerSecond, locale: en) == "15.6")
        #expect(SpeedFormatter.bar(1_240, unit: .megabytesPerSecond, locale: en) == "155")
    }

    @Test("Panel strings carry more precision and honour the unit")
    func panelValues() {
        #expect(SpeedFormatter.panel(5.312, locale: en) == "5.31")
        #expect(SpeedFormatter.panel(84.25, locale: en) == "84.3")
        #expect(SpeedFormatter.panel(178.4, locale: en) == "178")
        #expect(SpeedFormatter.panel(0.003, locale: en) == "<0.01")
        #expect(SpeedFormatter.panel(178.4, unit: .megabytesPerSecond, locale: en) == "22.3")
    }

    @Test("German locale uses a comma as the decimal separator")
    func germanLocale() {
        let de = Locale(identifier: "de_DE")
        #expect(SpeedFormatter.bar(84.2, locale: de) == "84,2")
        #expect(SpeedFormatter.bar(0.003, locale: de) == "<0,01")
    }

    @Test("Bar strings never exceed five characters, which is what pins the item width")
    func widthBound() {
        let values: [Double] = [0, 0.003, 0.04, 0.996, 9.99, 84.2, 99.95, 100, 999.4, 1000, 9999, 99_999]
        for value in values {
            for unit in SpeedUnit.allCases {
                #expect(SpeedFormatter.bar(value, unit: unit, locale: en).count <= 5,
                        "\(value) \(unit.rawValue) formatted too wide")
            }
        }
    }

    /// The width is pinned from these samples, so anything the bar can draw must be no
    /// wider than the widest of them.
    @Test("Width samples cover every string the bar can produce")
    func widestSamplesCoverNewStrings() {
        for unit in SpeedUnit.allCases {
            let samples = SpeedFormatter.widestBarSamples(unit: unit, locale: en)
            let longest = samples.map(\.count).max() ?? 0
            for value in [0.0, 0.003, 0.04, 5.3, 84.25, 512.7, 1_240.0, 99_999.0] {
                #expect(SpeedFormatter.bar(value, unit: unit, locale: en).count <= longest)
            }
            #expect(samples.contains("<0.01") || samples.contains("<0,01"))
        }
    }

    @Test("Durations read naturally")
    func durations() {
        #expect(DurationFormatter.humanReadable(8) == "8s")
        #expect(DurationFormatter.humanReadable(252) == "4m 12s")
        #expect(DurationFormatter.humanReadable(3_780) == "1h 03m")
    }
}
