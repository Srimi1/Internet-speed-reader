import Foundation
import Testing
@testable import SpeedCore

@Suite("Active direction selector")
struct ActiveDirectionSelectorTests {
    private var start: ContinuousClock.Instant { ContinuousClock.now }

    @Test("Rests on download when nothing meaningful is moving")
    func idleShowsDownload() {
        var selector = ActiveDirectionSelector()
        let direction = selector.update(downMbps: 0.01, upMbps: 0.02, now: start)
        // Upload is nominally higher here, but both are rounding noise.
        #expect(direction == .download)
    }

    @Test("A download keeps the download reading")
    func downloadStays() {
        var selector = ActiveDirectionSelector()
        let now = start
        for second in 0...5 {
            #expect(selector.update(
                downMbps: 120, upMbps: 1.2, uploadActivityMbps: 0,
                now: now.advanced(by: .seconds(second))
            ) == .download)
        }
    }

    @Test("A sustained upload takes priority even when a download is faster")
    func uploadTakesOver() {
        var selector = ActiveDirectionSelector()
        let now = start
        #expect(selector.update(downMbps: 100, upMbps: 1, uploadActivityMbps: 0.8, now: now) == .download)
        #expect(selector.update(downMbps: 100, upMbps: 1, uploadActivityMbps: 0.8,
                                now: now.advanced(by: .seconds(1))) == .download)
        #expect(selector.update(downMbps: 100, upMbps: 1, uploadActivityMbps: 0.8,
                                now: now.advanced(by: .seconds(2))) == .upload)
    }

    @Test("Short upload bursts never take the display")
    func shortBurstIgnored() {
        var selector = ActiveDirectionSelector()
        let now = start
        #expect(selector.update(downMbps: 1, upMbps: 40, now: now) == .download)
        #expect(selector.update(downMbps: 1, upMbps: 0.01,
                                now: now.advanced(by: .seconds(1))) == .download)
        #expect(selector.update(downMbps: 1, upMbps: 40,
                                now: now.advanced(by: .seconds(2))) == .download)
        #expect(selector.update(downMbps: 1, upMbps: 0.01,
                                now: now.advanced(by: .seconds(3))) == .download)
    }

    @Test("Upload exits after three seconds below the lower activity threshold")
    func exitHysteresis() {
        var selector = ActiveDirectionSelector()
        var now = start

        _ = selector.update(downMbps: 1, upMbps: 40, now: now)
        now = now.advanced(by: .seconds(2))
        #expect(selector.update(downMbps: 1, upMbps: 40, now: now) == .upload)
        now = now.advanced(by: .seconds(1))
        #expect(selector.update(downMbps: 90, upMbps: 1, uploadActivityMbps: 0.07, now: now) == .upload)
        now = now.advanced(by: .seconds(2))
        #expect(selector.update(downMbps: 90, upMbps: 1, uploadActivityMbps: 0.07, now: now) == .upload)
        now = now.advanced(by: .seconds(1))
        #expect(selector.update(downMbps: 90, upMbps: 1, uploadActivityMbps: 0.07, now: now) == .download)
    }

    @Test("Activity between thresholds retains an established upload")
    func middleBandKeepsUpload() {
        var selector = ActiveDirectionSelector()
        let now = start
        _ = selector.update(downMbps: 100, upMbps: 1, now: now)
        _ = selector.update(downMbps: 100, upMbps: 1, now: now.advanced(by: .seconds(2)))
        for second in 3...10 {
            #expect(selector.update(downMbps: 100, upMbps: 1, uploadActivityMbps: 0.1,
                                    now: now.advanced(by: .seconds(second))) == .upload)
        }
    }

    @Test("Idle immediately restores download and clears upload entry history")
    func idleAndResetClearHistory() {
        var selector = ActiveDirectionSelector()
        let now = start
        _ = selector.update(downMbps: 1, upMbps: 40, now: now)
        _ = selector.update(downMbps: 1, upMbps: 40, now: now.advanced(by: .seconds(2)))
        #expect(selector.current == .upload)
        #expect(selector.update(downMbps: 0, upMbps: 0,
                                now: now.advanced(by: .milliseconds(2100))) == .download)
        #expect(selector.update(downMbps: 1, upMbps: 40,
                                now: now.advanced(by: .seconds(3))) == .download)
        selector.reset()
        #expect(selector.update(downMbps: 1, upMbps: 40,
                                now: now.advanced(by: .seconds(10))) == .download)
    }
}
