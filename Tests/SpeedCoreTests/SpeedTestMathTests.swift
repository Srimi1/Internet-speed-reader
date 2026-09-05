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

    @Test("An unknown rate starts with the small initial probe")
    func firstProbe() {
        #expect(ladder.size(forPerStreamBytesPerSecond: 0) == ChunkLadder.firstProbeBytes)
    }
}

@Suite("Throughput aggregator")
struct ThroughputAggregatorTests {
    let aggregator = ThroughputAggregator()

    private func constant(_ rate: Double, seconds: Int = 6) -> [ThroughputSlice] {
        (1...(seconds * 10)).map {
            ThroughputSlice(mbps: rate, secondsSincePhaseStart: Double($0) / 10)
        }
    }

    @Test("Warm-up is excluded and steady payload is measured over actual time")
    func discardsWarmUp() throws {
        var slices = constant(100)
        for index in 0..<15 { slices[index] = ThroughputSlice(mbps: 0, secondsSincePhaseStart: Double(index + 1) / 10) }
        let summary = try aggregator.summarize(slices, totalBytes: 56_250_000, totalSeconds: 6)
        #expect(abs(summary.mbps - 100) < 0.001)
        #expect(abs(summary.meanMbps - 75) < 0.001)
        #expect(summary.quality == .good)
    }

    @Test("Real stalls lower delivered throughput and flag variable measurements")
    func retainsStalls() throws {
        var slices = constant(100)
        for index in 25..<35 { slices[index] = ThroughputSlice(mbps: 0, secondsSincePhaseStart: Double(index + 1) / 10) }
        let summary = try aggregator.summarize(slices, totalBytes: 62_500_000, totalSeconds: 6)
        #expect(abs(summary.mbps - 100 * 3.5 / 4.5) < 0.001)
        #expect(summary.quality == .variable)
    }

    @Test("Unequal callback intervals are time-weighted, not averaged by sample count")
    func irregularIntervals() throws {
        let slices = [
            ThroughputSlice(mbps: 10, secondsSincePhaseStart: 1.6, durationSeconds: 0.1),
            ThroughputSlice(mbps: 100, secondsSincePhaseStart: 2.5, durationSeconds: 0.9)
        ]
        let summary = try aggregator.summarize(slices, totalBytes: 11_375_000, totalSeconds: 2.5)
        #expect(abs(summary.mbps - 91) < 0.001)
        #expect(summary.quality == .shortSample)
    }

    @Test("An interval crossing warm-up contributes only its measured portion")
    func warmUpBoundary() throws {
        let slices = [ThroughputSlice(mbps: 80, secondsSincePhaseStart: 3, durationSeconds: 3)]
        let summary = try aggregator.summarize(slices, totalBytes: 30_000_000, totalSeconds: 3)
        #expect(abs(summary.mbps - 80) < 0.001)
        #expect(summary.quality == .shortSample)
    }

    @Test("Zero bytes and too little post-warm-up time never become successful results")
    func insufficientData() {
        #expect(throws: ThroughputAggregationError.self) {
            try aggregator.summarize(constant(0), totalBytes: 0, totalSeconds: 6)
        }
        #expect(throws: ThroughputAggregationError.self) {
            try aggregator.summarize(constant(50, seconds: 2), totalBytes: 1000, totalSeconds: 2)
        }
    }

    @Test("Cap-limited and incomplete measurements carry explicit quality")
    func qualityFlags() throws {
        let slices = constant(100)
        #expect(try aggregator.summarize(slices, totalBytes: 75_000_000, totalSeconds: 6, dataLimited: true).quality == .dataLimited)
        #expect(try aggregator.summarize(slices, totalBytes: 75_000_000, totalSeconds: 6, incomplete: true).quality == .incomplete)
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
