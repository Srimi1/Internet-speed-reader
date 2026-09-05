import Testing
@testable import SpeedCore

@Suite("Throughput calculator")
struct ThroughputCalculatorTests {
    let calc = ThroughputCalculator()

    @Test("A coalesced five-second Low Power Mode tick still produces a rate")
    func lowPowerCadenceAcceptsSchedulingTolerance() {
        let outcome = calc.evaluate(
            previous: IFCounters(rx: 0, tx: 0),
            current: IFCounters(rx: 6_562_500, tx: 0),
            elapsedSeconds: 5.25,
            expectedIntervalSeconds: 5
        )
        #expect(outcome == .rate(downMbps: 10, upMbps: 0))
    }

    @Test("Unexpected gaps are rejected relative to the requested cadence", arguments: [1.0, 2.0, 5.0])
    func cadenceAwareStaleness(cadence: Double) {
        let limit = max(5, 3 * cadence)
        let before = IFCounters(rx: 0, tx: 0)
        let after = IFCounters(rx: 1_250_000, tx: 0)
        #expect(calc.evaluate(
            previous: before, current: after, elapsedSeconds: limit + 0.01,
            expectedIntervalSeconds: cadence
        ) == .rebaseline(reason: .staleGap))
        guard case .rate = calc.evaluate(
            previous: before, current: after, elapsedSeconds: limit,
            expectedIntervalSeconds: cadence
        ) else { Issue.record("the cadence boundary should be accepted"); return }
    }

    @Test("A packet counter reset discards the entire reading")
    func packetResetRebaselines() {
        #expect(calc.evaluate(
            previous: IFCounters(rx: 0, tx: 100, txPackets: 5),
            current: IFCounters(rx: 100, tx: 200, txPackets: 1),
            elapsedSeconds: 1
        ) == .rebaseline(reason: .counterWentBackwards))
    }

    @Test("Control-sized outbound packets do not signal an upload")
    func controlPacketAllowance() {
        let before = IFCounters(rx: 0, tx: 0, txPackets: 0)
        let after = IFCounters(rx: 12_500_000, tx: 400_000, txPackets: 5_000)
        #expect(ThroughputCalculator.uploadActivityMbps(
            previous: before, current: after, elapsedSeconds: 1
        ) == 0)
        // The allowance only classifies activity; measured upload is still 3.2 Mbps.
        #expect(calc.evaluate(previous: before, current: after, elapsedSeconds: 1)
            == .rate(downMbps: 100, upMbps: 3.2))
    }

    @Test("Upload activity above the packet allowance uses measured time")
    func uploadPayloadActivity() {
        let activity = ThroughputCalculator.uploadActivityMbps(
            previous: IFCounters(rx: 0, tx: 0),
            current: IFCounters(rx: 250_000_000, tx: 300_000, txPackets: 300),
            elapsedSeconds: 2
        )
        #expect(abs(activity - 1.008) < 0.0001)
    }

    @Test("Rate divides by measured elapsed time, not the nominal interval")
    func usesMeasuredElapsedTime() {
        // 1_250_000 bytes = 10 Mbit. Over 1.0 s that is 10 Mbps; over 1.25 s it is 8.
        let previous = IFCounters(rx: 0, tx: 0)
        let current = IFCounters(rx: 1_250_000, tx: 0)

        guard case let .rate(down, _) = calc.evaluate(previous: previous, current: current, elapsedSeconds: 1.0) else {
            Issue.record("expected a rate"); return
        }
        #expect(abs(down - 10.0) < 0.0001)

        guard case let .rate(slower, _) = calc.evaluate(previous: previous, current: current, elapsedSeconds: 1.25) else {
            Issue.record("expected a rate"); return
        }
        #expect(abs(slower - 8.0) < 0.0001)
    }

    @Test("A counter going backwards rebaselines instead of emitting a spike")
    func counterResetRebaselines() {
        let outcome = calc.evaluate(
            previous: IFCounters(rx: 9_000_000, tx: 100),
            current: IFCounters(rx: 12_000, tx: 100),
            elapsedSeconds: 1.0
        )
        #expect(outcome == .rebaseline(reason: .counterWentBackwards))
    }

    @Test("A long gap is discarded rather than shown as a huge burst")
    func staleGapDiscarded() {
        let outcome = calc.evaluate(
            previous: IFCounters(rx: 0, tx: 0),
            current: IFCounters(rx: 500_000_000, tx: 0),
            elapsedSeconds: 900
        )
        #expect(outcome == .rebaseline(reason: .staleGap))
    }

    @Test("Sub-threshold intervals keep the existing baseline")
    func tooSoon() {
        let outcome = calc.evaluate(
            previous: IFCounters(rx: 0, tx: 0),
            current: IFCounters(rx: 10, tx: 10),
            elapsedSeconds: 0.05
        )
        #expect(outcome == .tooSoon)
    }

    @Test("Implausibly fast samples are dropped")
    func implausibleRate() {
        let outcome = calc.evaluate(
            previous: IFCounters(rx: 0, tx: 0),
            current: IFCounters(rx: 50_000_000_000, tx: 0),
            elapsedSeconds: 1.0
        )
        #expect(outcome == .rebaseline(reason: .implausibleRate))
    }

    @Test("Counters near the 32-bit boundary are handled as plain 64-bit values")
    func aboveThirtyTwoBitBoundary() {
        // 6_082_856_020 is a real en0 reading from the development machine, well past 2^32.
        let previous = IFCounters(rx: 6_082_856_020, tx: 0)
        let current = IFCounters(rx: 6_082_856_020 + 1_250_000, tx: 0)
        guard case let .rate(down, _) = calc.evaluate(previous: previous, current: current, elapsedSeconds: 1.0) else {
            Issue.record("expected a rate"); return
        }
        #expect(abs(down - 10.0) < 0.0001)
    }
}

@Suite("Live throughput smoothing")
struct ThroughputSmootherTests {
    @Test("The same elapsed time produces the same smoothing at different cadences")
    func smoothingUsesElapsedTime() {
        var fast = ThroughputSmoother()
        var slow = ThroughputSmoother()
        _ = fast.update(downMbps: 10, upMbps: 2, elapsedSeconds: 1)
        _ = slow.update(downMbps: 10, upMbps: 2, elapsedSeconds: 1)
        var fastResult = (downMbps: 0.0, upMbps: 0.0)
        for _ in 0..<5 {
            fastResult = fast.update(downMbps: 100, upMbps: 20, elapsedSeconds: 1)
        }
        let slowResult = slow.update(downMbps: 100, upMbps: 20, elapsedSeconds: 5)
        #expect(abs(fastResult.downMbps - slowResult.downMbps) < 0.0001)
        #expect(abs(fastResult.upMbps - slowResult.upMbps) < 0.0001)
    }

    @Test("Measured idle and a new baseline never display an old transfer")
    func idleAndReset() {
        var smoother = ThroughputSmoother()
        _ = smoother.update(downMbps: 100, upMbps: 20, elapsedSeconds: 1)
        let idle = smoother.update(downMbps: 0, upMbps: 0, elapsedSeconds: 1)
        #expect(idle.downMbps == 0)
        #expect(idle.upMbps == 0)
        _ = smoother.update(downMbps: 100, upMbps: 20, elapsedSeconds: 1)
        let background = smoother.update(downMbps: 0.001, upMbps: 0.002, elapsedSeconds: 1)
        #expect(background.downMbps == 0.001)
        #expect(background.upMbps == 0.002)
        smoother.reset()
        let first = smoother.update(downMbps: 5, upMbps: 1, elapsedSeconds: 1)
        #expect(first.downMbps == 5)
        #expect(first.upMbps == 1)
    }
}
