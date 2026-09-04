import Foundation
import Testing
@testable import SpeedCore

@Suite("Server timing parser")
struct ServerTimingTests {
    @Test("Edge and worker durations are summed, since both are server time")
    func edgeAndWorker() {
        let timing = ServerTiming.parse("cfSpeedEdge;dur=3, cfSpeedWorker;dur=22")
        #expect(timing.edgeMs == 3)
        #expect(timing.workerMs == 22)
        #expect(timing.totalServerMs == 25)
    }

    @Test("A cold worker's large duration is captured rather than ignored")
    func coldWorker() {
        // Observed live: a cold worker took 335 ms while the edge stayed at 3 ms.
        // Failing to subtract this turns a 30 ms link into a 350 ms "ping".
        let timing = ServerTiming.parse("cfSpeedEdge;dur=3, cfSpeedWorker;dur=335")
        #expect(timing.totalServerMs == 338)
    }

    @Test("cfL4 round trips convert from microseconds to milliseconds")
    func l4Parsing() {
        let header = #"cfL4;desc="?proto=TCP&rtt=30998&min_rtt=29701&rtt_var=12064&sent=5&lost=0""#
        let timing = ServerTiming.parse(header)
        #expect(abs((timing.tcpRttMs ?? 0) - 30.998) < 0.001)
        #expect(abs((timing.tcpMinRttMs ?? 0) - 29.701) < 0.001)
    }

    @Test("Missing or malformed headers yield zeros rather than crashing")
    func malformed() {
        #expect(ServerTiming.parse(nil).totalServerMs == 0)
        #expect(ServerTiming.parse("garbage").totalServerMs == 0)
        #expect(ServerTiming.parse("cfSpeedEdge").totalServerMs == 0)
    }
}

@Suite("Chunk ladder")
struct ChunkLadderTests {
    let ladder = ChunkLadder()

    @Test("Sizes about two seconds of work per request")
    func twoSecondTarget() {
        // 12.5 MB/s per stream, so two seconds is 25 MB, rounded up to 32 MiB.
        let size = ladder.size(forPerStreamBytesPerSecond: 12_500_000)
        #expect(size == 33_554_432)
    }

    @Test("Never exceeds the 50 MiB ceiling that Cloudflare rejects with a 403")
    func respectsCeiling() {
        #expect(ladder.size(forPerStreamBytesPerSecond: 500_000_000) == ChunkLadder.maxBytes)
    }

    @Test("Slow links stay at the floor rather than requesting a few bytes at a time")
    func respectsFloor() {
        #expect(ladder.size(forPerStreamBytesPerSecond: 1_000) == ChunkLadder.minBytes)
    }

    @Test("An unknown rate starts with the 1 MiB probe")
    func firstProbe() {
        #expect(ladder.size(forPerStreamBytesPerSecond: 0) == ChunkLadder.firstProbeBytes)
    }
}

@Suite("Throughput aggregator")
struct ThroughputAggregatorTests {
    let aggregator = ThroughputAggregator()

    /// A ramp from zero to 100 Mbps over 1.5 s, then steady 100 Mbps.
    private func rampThenSteady(steadySlices: Int = 60) -> [ThroughputSlice] {
        var slices: [ThroughputSlice] = []
        for step in 0..<15 {
            let t = Double(step) * 0.1
            slices.append(ThroughputSlice(mbps: 100 * (t / 1.5), secondsSincePhaseStart: t))
        }
        for step in 0..<steadySlices {
            let t = 1.5 + Double(step) * 0.1
            slices.append(ThroughputSlice(mbps: 100, secondsSincePhaseStart: t))
        }
        return slices
    }

    @Test("The warm-up ramp is discarded, so the headline reflects steady state")
    func discardsWarmUp() throws {
        let summary = try aggregator.summarize(rampThenSteady(), totalBytes: 100_000_000, totalSeconds: 7.5)
        // Without the warm-up discard the ramp would drag this well below 100.
        #expect(abs(summary.mbps - 100) < 0.5)
        #expect(summary.quality == .good)
    }

    @Test("A brief stall is trimmed away rather than halving the result")
    func trimsStalls() throws {
        var slices = rampThenSteady()
        for index in 20..<28 { slices[index] = ThroughputSlice(mbps: 2, secondsSincePhaseStart: slices[index].secondsSincePhaseStart) }
        let summary = try aggregator.summarize(slices, totalBytes: 90_000_000, totalSeconds: 7.5)
        #expect(summary.mbps > 90, "a short stall should not dominate the headline")
    }

    @Test("The byte-weighted mean is reported alongside, as an untrimmed cross-check")
    func reportsMean() throws {
        let summary = try aggregator.summarize(rampThenSteady(), totalBytes: 93_750_000, totalSeconds: 7.5)
        #expect(abs(summary.meanMbps - 100) < 0.5)
    }

    @Test("Too few slices is an error, not a confidently wrong number")
    func insufficientData() {
        let slices = (0..<4).map { ThroughputSlice(mbps: 50, secondsSincePhaseStart: Double($0) * 0.1) }
        #expect(throws: ThroughputAggregationError.self) {
            try aggregator.summarize(slices, totalBytes: 1000, totalSeconds: 0.4)
        }
    }

    @Test("A short phase still reports, but is flagged as a rough sample")
    func shortSampleFlag() throws {
        let summary = try aggregator.summarize(rampThenSteady(steadySlices: 12), totalBytes: 20_000_000, totalSeconds: 2.7)
        #expect(summary.quality == .shortSample)
    }
}

@Suite("Byte ledger")
struct ByteLedgerTests {
    @Test("Concurrent streams all count into one total")
    func concurrentAdds() async {
        let ledger = ByteLedger()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1_000 { ledger.add(1_024) }
                }
            }
        }
        // Eight streams is what makes this the sum rather than an average.
        #expect(ledger.bytes == 8 * 1_000 * 1_024)
    }
}
