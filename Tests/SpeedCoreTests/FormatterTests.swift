import Foundation
import Testing
@testable import SpeedCore

@Suite("Formatters")
struct FormatterTests {
    let en = Locale(identifier: "en_US")

    @Test("Bar strings stay compact across every magnitude")
    func barMagnitudes() {
        #expect(SpeedFormatter.bar(0, locale: en) == "0.0")
        #expect(SpeedFormatter.bar(0.02, locale: en) == "0.0")
        #expect(SpeedFormatter.bar(8.44, locale: en) == "8.4")
        #expect(SpeedFormatter.bar(84.25, locale: en) == "84.3")
        #expect(SpeedFormatter.bar(512.7, locale: en) == "513")
        #expect(SpeedFormatter.bar(1_240, locale: en) == "1.2G")
    }

    @Test("Megabytes per second divides by eight")
    func megabytes() {
        #expect(SpeedFormatter.bar(80, unit: .megabytesPerSecond, locale: en) == "10.0")
    }

    @Test("German locale uses a comma as the decimal separator")
    func germanLocale() {
        let de = Locale(identifier: "de_DE")
        #expect(SpeedFormatter.bar(84.2, locale: de) == "84,2")
    }

    @Test("Bar strings never exceed five characters, which is what pins the item width")
    func widthBound() {
        let values: [Double] = [0, 0.04, 9.99, 84.2, 99.95, 100, 999.4, 1000, 9999, 99_999]
        for value in values {
            #expect(SpeedFormatter.bar(value, locale: en).count <= 5, "\(value) formatted too wide")
        }
    }

    @Test("Durations read naturally")
    func durations() {
        #expect(DurationFormatter.humanReadable(8) == "8s")
        #expect(DurationFormatter.humanReadable(252) == "4m 12s")
        #expect(DurationFormatter.humanReadable(3_780) == "1h 03m")
    }
}
