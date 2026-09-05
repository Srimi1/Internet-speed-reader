import Foundation
import Testing
@testable import SpeedCore

@Suite("Transfer activity detector")
struct TransferActivityDetectorTests {
    private let start = ContinuousClock.now

    /// Feeds a steady rate for a number of one-second ticks and returns the final state.
    @discardableResult
    private func feed(
        _ detector: inout TransferActivityDetector,
        mbps: Double,
        seconds: Int,
        from offset: Int = 0
    ) -> TransferActivityDetector.State {
        var state = detector.state
        for second in 0..<seconds {
            state = detector.update(
                activityMbps: mbps,
                elapsedSeconds: 1,
                now: start.advanced(by: .seconds(offset + second))
            )
        }
        return state
    }

    /// The machine's own background chatter (push notifications, sync, telemetry) runs at
    /// a few tenths of a megabit. It must never look like a transfer.
    @Test("Background chatter never activates the detector")
    func chatterNeverActivates() {
        var detector = TransferActivityDetector()
        for second in 0..<600 {
            let chatter = [0.05, 0.12, 0.3, 0.08, 0.2][second % 5]
            _ = detector.update(activityMbps: chatter, elapsedSeconds: 1, now: start.advanced(by: .seconds(second)))
        }
        #expect(detector.state == .idle)
    }

    @Test("A sustained transfer activates within a few seconds")
    func sustainedTransferActivates() {
        var detector = TransferActivityDetector()
        #expect(feed(&detector, mbps: 20, seconds: 1) == .active)
    }

    @Test("A moderate stream activates once the window fills")
    func moderateStreamActivates() {
        var detector = TransferActivityDetector()
        // 1.2 Mbps is 150 kB/s: below entry for one tick, above it across the window.
        #expect(feed(&detector, mbps: 1.2, seconds: 1) == .idle)
        #expect(feed(&detector, mbps: 1.2, seconds: 2, from: 1) == .active)
    }

    /// A streamed answer goes quiet while the model thinks or calls a tool. Releasing
    /// after three seconds would make the emphasis flicker through a single response.
    @Test("A short pause inside a transfer keeps it active")
    func shortPauseKeepsActive() {
        var detector = TransferActivityDetector()
        feed(&detector, mbps: 20, seconds: 3)
        #expect(detector.state == .active)
        feed(&detector, mbps: 0, seconds: 6, from: 3)
        #expect(detector.state == .active)
    }

    @Test("The detector releases after a long enough quiet period")
    func releasesAfterQuiet() {
        var detector = TransferActivityDetector()
        feed(&detector, mbps: 20, seconds: 3)
        feed(&detector, mbps: 0, seconds: 12, from: 3)
        #expect(detector.state == .idle)
    }

    /// Exit is measured on the same statistic as entry, so a machine whose idle floor sits
    /// near the exit threshold still releases instead of latching on forever.
    @Test("Chatter after a transfer still releases the detector")
    func chatterAfterTransferReleases() {
        var detector = TransferActivityDetector()
        feed(&detector, mbps: 20, seconds: 3)
        for second in 0..<20 {
            _ = detector.update(activityMbps: 0.25, elapsedSeconds: 1, now: start.advanced(by: .seconds(3 + second)))
        }
        #expect(detector.state == .idle)
    }

    @Test("A brief burst holds the display for a minimum time")
    func minimumActiveTime() {
        var detector = TransferActivityDetector()
        _ = detector.update(activityMbps: 40, elapsedSeconds: 1, now: start)
        #expect(detector.state == .active)
        _ = detector.update(activityMbps: 0, elapsedSeconds: 1, now: start.advanced(by: .seconds(1)))
        #expect(detector.state == .active)
    }

    /// On a slow cadence one sample covers five seconds of traffic and must count for all
    /// of it, or a low-power Mac would never register a transfer.
    @Test("A slow cadence weights each sample by its measured time")
    func slowCadenceWeighting() {
        var detector = TransferActivityDetector()
        let state = detector.update(activityMbps: 1.0, elapsedSeconds: 5, now: start)
        #expect(state == .active)
        #expect(detector.state == .active)
    }

    @Test("Reset returns to idle immediately")
    func resetIsImmediate() {
        var detector = TransferActivityDetector()
        feed(&detector, mbps: 40, seconds: 3)
        #expect(detector.state == .active)
        detector.reset()
        #expect(detector.state == .idle)
    }
}
