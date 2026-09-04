import Testing
@testable import SpeedCore

@Suite("Throughput calculator")
struct ThroughputCalculatorTests {
    let calc = ThroughputCalculator()

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
