import Foundation
import Testing
@testable import SpeedCore

@Suite("Live readout model")
struct LiveReadoutModelTests {
    private let start = ContinuousClock.now

    @Test("A sample is shown as a fresh reading")
    func sampleIsFresh() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 5.3, upMbps: 0.2, at: start)
        let presentation = model.presentation(now: start)
        #expect(presentation.freshness == .fresh)
        #expect(presentation.downMbps == 5.3)
        #expect(presentation.upMbps == 0.2)
        #expect(presentation.hasReading)
    }

    /// One late tick or a single failed counter read must not blank the menu bar: v1
    /// replaced the numbers with a dash for two full cadences every time this happened.
    @Test("A transient gap holds the last reading, then gives up")
    func transientHoldThenUnavailable() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 12, upMbps: 1, at: start)
        model.unavailable(.stale, at: start, expectedIntervalSeconds: 1)

        let held = model.presentation(now: start.advanced(by: .seconds(2)))
        #expect(held.freshness == .holding)
        #expect(held.downMbps == 12)

        let hold = LiveReadoutModel.holdSeconds(expectedIntervalSeconds: 1)
        let expired = model.presentation(now: start.advanced(by: .seconds(hold + 0.5)))
        #expect(expired.freshness == .unavailable)
        #expect(expired.downMbps == 0)
    }

    @Test("A new sample during the hold restores the fresh state")
    func sampleDuringHoldRestoresFresh() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 12, upMbps: 1, at: start)
        model.unavailable(.counterUnavailable, at: start, expectedIntervalSeconds: 1)
        model.sample(downMbps: 8, upMbps: 2, at: start.advanced(by: .seconds(1)))
        let presentation = model.presentation(now: start.advanced(by: .seconds(1)))
        #expect(presentation.freshness == .fresh)
        #expect(presentation.downMbps == 8)
    }

    /// Sleep and a missing interface are not transient: the source is genuinely gone, so
    /// holding a stale number would be a lie.
    @Test("Terminal reasons clear the reading immediately")
    func terminalReasonsAreImmediate() {
        for reason in [LiveThroughputUnavailableReason.paused, .noInterface] {
            var model = LiveReadoutModel()
            model.sample(downMbps: 12, upMbps: 1, at: start)
            model.unavailable(reason, at: start, expectedIntervalSeconds: 1)
            #expect(model.presentation(now: start).freshness == .unavailable)
        }
    }

    @Test("The hold window scales with the sampling cadence")
    func holdScalesWithCadence() {
        let oneSecond = LiveReadoutModel.holdSeconds(expectedIntervalSeconds: 1)
        let fiveSecond = LiveReadoutModel.holdSeconds(expectedIntervalSeconds: 5)
        #expect(fiveSecond > oneSecond)
        // Never shorter than the sampler's own tolerance, or the display would blank while
        // the sampler still considers the gap normal.
        #expect(oneSecond >= ThroughputCalculator.maximumGapSeconds(expectedIntervalSeconds: 1))
        #expect(fiveSecond >= ThroughputCalculator.maximumGapSeconds(expectedIntervalSeconds: 5))
    }

    /// The refresh loop runs at 500 ms while the sampler ticks at 1 s. Requesting a new
    /// baseline on every pass would drop it before a delta could ever be measured.
    @Test("The rebaseline request fires once per staleness episode")
    func rebaselineFiresOnce() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 5, upMbps: 1, at: start)
        model.unavailable(.stale, at: start, expectedIntervalSeconds: 1)

        var fires = 0
        for step in 1...20 {
            let now = start.advanced(by: .milliseconds(500 * step))
            if model.needsRebaseline(now: now, expectedIntervalSeconds: 1) { fires += 1 }
        }
        #expect(fires == 1)

        // A recovered sample re-arms it for the next episode.
        model.sample(downMbps: 5, upMbps: 1, at: start.advanced(by: .seconds(11)))
        model.unavailable(.stale, at: start.advanced(by: .seconds(11)), expectedIntervalSeconds: 1)
        let refires = model.needsRebaseline(now: start.advanced(by: .seconds(30)), expectedIntervalSeconds: 1)
        #expect(refires)
    }

    @Test("No rebaseline is requested while readings are arriving")
    func noRebaselineWhenFresh() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 5, upMbps: 1, at: start)
        let immediately = model.needsRebaseline(now: start.advanced(by: .milliseconds(500)), expectedIntervalSeconds: 1)
        let shortly = model.needsRebaseline(now: start.advanced(by: .seconds(3)), expectedIntervalSeconds: 1)
        #expect(!immediately)
        #expect(!shortly)
    }

    @Test("The last sample instant survives a hold so callers can time the gap")
    func lastSampleSurvivesHold() {
        var model = LiveReadoutModel()
        model.sample(downMbps: 5, upMbps: 1, at: start)
        model.unavailable(.stale, at: start.advanced(by: .seconds(1)), expectedIntervalSeconds: 1)
        #expect(model.lastSampleInstant == start)
        model.reset(message: "Paused")
        #expect(model.lastSampleInstant == nil)
    }

    @Test("Each unavailable reason explains itself")
    func messagesAreDistinct() {
        var messages = Set<String>()
        for reason in [LiveThroughputUnavailableReason.starting, .noInterface, .counterUnavailable, .paused, .stale] {
            var model = LiveReadoutModel()
            model.unavailable(reason, at: start, expectedIntervalSeconds: 1)
            messages.insert(model.presentation(now: start).message)
        }
        #expect(messages.count == 5)
    }
}
