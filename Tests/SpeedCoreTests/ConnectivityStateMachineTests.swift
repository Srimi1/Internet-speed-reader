import Foundation
import Testing
@testable import SpeedCore

/// Drives the machine with hand-controlled time so every timing rule is deterministic.
private struct Driver {
    var machine = ConnectivityStateMachine()
    var now = ContinuousClock.now
    var wall = Date(timeIntervalSince1970: 1_700_000_000)

    mutating func advance(_ seconds: Double) {
        now = now.advanced(by: .seconds(seconds))
        wall = wall.addingTimeInterval(seconds)
    }

    @discardableResult
    mutating func send(_ event: ConnectivityStateMachine.Event) -> [ConnectivityStateMachine.Effect] {
        machine.handle(event, now: now, wallClock: wall)
    }

    @discardableResult
    mutating func fail(_ kind: ProbeFailureKind = .timedOut) -> [ConnectivityStateMachine.Effect] {
        send(.probe(.offline(kind: kind)))
    }

    @discardableResult
    mutating func succeed() -> [ConnectivityStateMachine.Effect] {
        send(.probe(.online(rttMs: 20, viaFallback: false)))
    }
}

private extension Array where Element == ConnectivityStateMachine.Effect {
    var opensOutage: Bool { contains { if case .openOutage = $0 { return true }; return false } }
    var closesOutage: Bool { contains { if case .closeOutage = $0 { return true }; return false } }
    var notifiesDown: Bool { contains(.notifyDown) }
    var notifiesUp: Bool { contains(.notifyUp) }
    var outageStart: Date? {
        for effect in self { if case let .openOutage(_, start, _, _) = effect { return start } }
        return nil
    }
}

@Suite("Connectivity state machine")
struct ConnectivityStateMachineTests {
    @Test("One failure is not an outage; the second confirms it")
    func twoFailuresConfirm() {
        var driver = Driver()
        driver.succeed()

        let first = driver.fail()
        #expect(!first.opensOutage)
        #expect(driver.machine.state == .suspect(failures: 1))

        driver.advance(2)
        let second = driver.fail()
        #expect(second.opensOutage)
        #expect(driver.machine.state == .down)
    }

    @Test("The outage start is the first failure, not the confirming one")
    func honestStartTime() {
        var driver = Driver()
        driver.succeed()

        let firstFailureWall = driver.wall
        driver.fail()
        driver.advance(2)
        let effects = driver.fail()

        // A start stamped at the confirming probe would under-report every outage by
        // the length of the confirmation delay.
        #expect(effects.outageStart == firstFailureWall)
    }

    @Test("A single success clears an outage immediately")
    func oneSuccessRecovers() {
        var driver = Driver()
        driver.fail(); driver.advance(2); driver.fail()
        #expect(driver.machine.state == .down)

        driver.advance(2)
        let effects = driver.succeed()
        #expect(effects.closesOutage)
        #expect(driver.machine.state == .online)
    }

    @Test("A blip that recovers before confirmation leaves no record at all")
    func blipLeavesNoRecord() {
        var driver = Driver()
        driver.succeed()
        driver.fail()
        driver.advance(1)
        let effects = driver.succeed()
        #expect(!effects.opensOutage)
        #expect(!effects.closesOutage)
    }

    @Test("An unsatisfied path waits out the debounce, so an access point roam stays silent")
    func pathDebounce() {
        var driver = Driver()
        driver.succeed()

        let immediate = driver.send(.path(status: .unsatisfied, reason: "Wi-Fi is off", interfaceName: "en0", interfaceChanged: false))
        #expect(!immediate.opensOutage)

        driver.advance(1)
        let stillEarly = driver.send(.path(status: .unsatisfied, reason: "Wi-Fi is off", interfaceName: "en0", interfaceChanged: false))
        #expect(!stillEarly.opensOutage)

        driver.advance(3)
        let confirmed = driver.send(.path(status: .unsatisfied, reason: "Wi-Fi is off", interfaceName: "en0", interfaceChanged: false))
        #expect(confirmed.opensOutage)
    }

    @Test("A satisfied path only schedules a probe, because a captive portal satisfies it too")
    func satisfiedPathDoesNotDeclareOnline() {
        var driver = Driver()
        driver.fail(); driver.advance(2); driver.fail()

        let effects = driver.send(.path(status: .satisfied, reason: nil, interfaceName: "en0", interfaceChanged: false))
        #expect(!effects.closesOutage)
        #expect(driver.machine.state == .down)
    }

    @Test("A captive portal is its own state, not a plain outage")
    func captivePortalState() {
        var driver = Driver()
        let effects = driver.send(.probe(.captivePortal))
        #expect(effects.opensOutage)
        #expect(driver.machine.state == .captivePortal)
    }

    @Test("The drop banner waits for the notify threshold")
    func notifyThreshold() {
        var driver = Driver()
        driver.succeed()
        driver.advance(30)          // clear the launch grace
        driver.fail(); driver.advance(2); driver.fail()

        driver.advance(3)
        #expect(!driver.send(.tick).notifiesDown)

        driver.advance(10)
        #expect(driver.send(.tick).notifiesDown)
    }

    @Test("Waking from sleep suppresses the banner but still records the outage")
    func wakeGraceGatesBannersOnly() {
        var driver = Driver()
        driver.send(.didWake)

        driver.advance(1)
        driver.fail()
        driver.advance(2)
        let opened = driver.fail()
        // The record is created immediately: the log must stay honest even while
        // banners are suppressed.
        #expect(opened.opensOutage)

        driver.advance(11)
        #expect(!driver.send(.tick).notifiesDown, "still inside the 20 s wake grace")

        driver.advance(10)
        #expect(driver.send(.tick).notifiesDown, "past the grace, so the banner fires")
    }

    @Test("Sleeping closes an open outage instead of leaving it running all night")
    func sleepClosesOutage() {
        var driver = Driver()
        driver.fail(); driver.advance(2); driver.fail()

        let effects = driver.send(.willSleep)
        #expect(effects.contains { effect in
            if case let .closeOutage(_, reason) = effect { return reason == .sleep }
            return false
        })
        #expect(driver.machine.state == .suspended(reason: .sleep))
    }

    @Test("Every event is ignored while suspended, which is what makes dark wakes safe")
    func suspendedIgnoresEvents() {
        var driver = Driver()
        driver.send(.willSleep)

        #expect(driver.fail().isEmpty)
        #expect(driver.send(.path(status: .unsatisfied, reason: nil, interfaceName: "en0", interfaceChanged: false)).isEmpty)
        #expect(driver.send(.tick).isEmpty)
        #expect(driver.machine.state == .suspended(reason: .sleep))
    }

    @Test("A restore banner only fires when a drop banner did")
    func upOnlyAfterDown() {
        var driver = Driver()
        driver.succeed()
        driver.advance(30)
        driver.fail(); driver.advance(2); driver.fail()

        driver.advance(2)
        let quickRecovery = driver.succeed()
        #expect(quickRecovery.closesOutage)
        #expect(!quickRecovery.notifiesUp, "no drop banner was shown, so no restore banner either")

        driver.advance(5)
        driver.fail(); driver.advance(2); driver.fail()
        driver.advance(15)
        #expect(driver.send(.tick).notifiesDown)
        driver.advance(5)
        #expect(driver.succeed().notifiesUp)
    }

    @Test("Repeated failures back off the probe cadence")
    func backoffAfterManyFailures() {
        var driver = Driver()
        var lastCadence: Duration = .zero
        for _ in 0..<12 {
            let effects = driver.fail()
            for effect in effects {
                if case let .scheduleProbe(after) = effect { lastCadence = after }
            }
            driver.advance(2)
        }
        #expect(lastCadence == .seconds(30))
    }

    @Test("Paused alerts suppress banners but keep recording outages")
    func pausedAlerts() {
        var driver = Driver()
        driver.succeed()
        driver.advance(30)
        driver.machine.setAlertsPaused(true)

        driver.fail(); driver.advance(2)
        let opened = driver.fail()
        #expect(opened.opensOutage)

        driver.advance(30)
        #expect(!driver.send(.tick).notifiesDown)
    }

    @Test("A speed test suspends the engine so its own traffic cannot look like an outage")
    func speedTestSuspends() {
        var driver = Driver()
        driver.send(.speedTestStarted)
        #expect(driver.machine.state == .suspended(reason: .speedTest))
        #expect(driver.fail().isEmpty)

        driver.send(.speedTestFinished(success: true))
        #expect(driver.machine.state == .online)
    }
}
