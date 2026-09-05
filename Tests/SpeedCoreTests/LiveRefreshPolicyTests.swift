import Testing
@testable import SpeedCore

struct LiveRefreshPolicyTests {
    @Test func migrationPreservesOnlyExplicitBatteryPreference() {
        #expect(LiveRefreshPolicy(storedValue: nil) == .always)
        #expect(LiveRefreshPolicy(storedValue: "onlyWhenOpen") == .always)
        #expect(LiveRefreshPolicy(storedValue: "reduceOnBattery") == .reduceOnBattery)
        #expect(LiveRefreshPolicy(storedValue: "unknown") == .always)
    }

    @Test func powerTransitionsApplyWithoutChangingThePreference() {
        #expect(LiveRefreshPolicy.always.interval(isOnBattery: true, isLowPowerMode: true) == 1)
        #expect(LiveRefreshPolicy.reduceOnBattery.interval(isOnBattery: false, isLowPowerMode: false) == 1)
        #expect(LiveRefreshPolicy.reduceOnBattery.interval(isOnBattery: true, isLowPowerMode: false) == 2)
        #expect(LiveRefreshPolicy.reduceOnBattery.interval(isOnBattery: true, isLowPowerMode: true) == 5)
        #expect(LiveRefreshPolicy.reduceOnBattery.interval(isOnBattery: false, isLowPowerMode: true) == 5)
    }
}
