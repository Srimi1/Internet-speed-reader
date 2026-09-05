import Foundation
import Testing
@testable import SpeedCore

@Suite("Bar layout")
struct BarLayoutTests {
    /// A fresh install, and any unreadable preference, must land on the layout that shows
    /// download and upload at the same time.
    @Test("Missing and unknown preferences resolve to both directions")
    func defaultsToTwoLine() {
        #expect(BarLayout(storedValue: nil) == .twoLine)
        #expect(BarLayout(storedValue: "") == .twoLine)
        #expect(BarLayout(storedValue: "sideways") == .twoLine)
    }

    @Test("Stored layouts are honoured")
    func storedValuesRoundTrip() {
        for layout in BarLayout.allCases {
            #expect(BarLayout(storedValue: layout.rawValue) == layout)
        }
    }

    @Test("Raw values are the stored preference strings and must not drift")
    func rawValuesAreStable() {
        #expect(BarLayout.twoLine.rawValue == "twoLine")
        #expect(BarLayout.oneLine.rawValue == "oneLine")
        #expect(BarLayout.adaptive.rawValue == "adaptive")
        #expect(BarLayout.dotOnly.rawValue == "dotOnly")
    }

    @Test("Only the stacked and single-row layouts show both directions")
    func bothDirections() {
        #expect(BarLayout.twoLine.showsBothDirections)
        #expect(BarLayout.oneLine.showsBothDirections)
        #expect(!BarLayout.adaptive.showsBothDirections)
        #expect(!BarLayout.dotOnly.showsBothDirections)
    }
}
