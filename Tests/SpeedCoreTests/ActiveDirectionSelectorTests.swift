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
        #expect(selector.update(downMbps: 120, upMbps: 1.2, now: start) == .download)
    }

    @Test("A real upload takes over the display")
    func uploadTakesOver() {
        var selector = ActiveDirectionSelector()
        let now = start
        #expect(selector.update(downMbps: 0.8, upMbps: 45, now: now) == .upload)
    }

    @Test("Upload must clearly dominate, not merely edge ahead")
    func needsClearDominance() {
        var selector = ActiveDirectionSelector()
        // Upload is ahead, but only slightly: not worth changing what the user reads.
        #expect(selector.update(downMbps: 10, upMbps: 11, now: start) == .download)
    }

    @Test("The direction holds for the dwell time instead of flickering")
    func dwellPreventsFlicker() {
        var selector = ActiveDirectionSelector()
        var now = start

        #expect(selector.update(downMbps: 1, upMbps: 40, now: now) == .upload)

        // A download burst one second later must not immediately steal the display.
        now = now.advanced(by: .seconds(1))
        #expect(selector.update(downMbps: 90, upMbps: 1, now: now) == .upload)

        // Once the dwell time has passed, it follows the traffic.
        now = now.advanced(by: .seconds(3))
        #expect(selector.update(downMbps: 90, upMbps: 1, now: now) == .download)
    }

    @Test("A mixed transfer settles rather than oscillating every sample")
    func mixedTrafficSettles() {
        var selector = ActiveDirectionSelector()
        var now = start
        var switches = 0
        var previous = selector.current

        // Alternating dominance every sample, which is the worst case for readability.
        for step in 0..<20 {
            let down = step.isMultiple(of: 2) ? 50.0 : 5.0
            let up = step.isMultiple(of: 2) ? 5.0 : 50.0
            now = now.advanced(by: .seconds(1))
            let direction = selector.update(downMbps: down, upMbps: up, now: now)
            if direction != previous { switches += 1; previous = direction }
        }
        // Twenty seconds of alternating traffic, capped by a three second dwell.
        #expect(switches <= 7, "the readout changed \(switches) times in 20 s")
    }
}
