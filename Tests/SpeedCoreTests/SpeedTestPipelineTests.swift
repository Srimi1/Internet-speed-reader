import Foundation
import os
import Testing
@testable import SpeedCore

private final class MeasurementClock: TimeSource, Sendable {
    private struct Sleeper { let deadline: Duration; let continuation: CheckedContinuation<Void, Error> }
    private struct State { var elapsed = Duration.zero; var sleepers: [UUID: Sleeper] = [:]; var cancelled: Set<UUID> = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let origin = ContinuousClock.now
    func now() -> ContinuousClock.Instant { origin.advanced(by: state.withLock { $0.elapsed }) }
    func wallClock() -> Date { Date(timeIntervalSince1970: state.withLock { $0.elapsed.seconds }) }
    func sleep(for duration: Duration, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers[id] = Sleeper(deadline: state.elapsed + duration, continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = self.state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
    func advance(_ duration: Duration) {
        let ready = state.withLock { state -> [Sleeper] in
            state.elapsed += duration
            let ids = state.sleepers.filter { $0.value.deadline <= state.elapsed }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class TransferStats: Sendable {
    struct State { var requests: [Int] = []; var active = 0; var cancelled = 0 }
    let value = OSAllocatedUnfairLock(initialState: State())
}

private final class ScriptedTransfer: SpeedTestStream, Sendable {
    typealias Script = @Sendable (Int, Int, @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt
    let stats: TransferStats
    let script: Script
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    init(stats: TransferStats, script: @escaping Script) { self.stats = stats; self.script = script }
    func download(bytes: Int, nonce: String, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        try await perform(bytes: bytes, progress: progress)
    }
    func upload(bytes: Int, file: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        try await perform(bytes: bytes, progress: progress)
    }
    private func perform(bytes: Int, progress: @escaping @Sendable (Int) -> Void) async throws -> TransferReceipt {
        let call = calls.withLock { $0 += 1; return $0 }
        stats.value.withLock { $0.requests.append(bytes); $0.active += 1 }
        defer { stats.value.withLock { $0.active -= 1 } }
        do { return try await script(call, bytes, progress) }
        catch is CancellationError { stats.value.withLock { $0.cancelled += 1 }; throw CancellationError() }
    }
    func invalidate() {}
}

private struct ScriptedTransport: CloudflareTransport {
    let stats: TransferStats
    let script: ScriptedTransfer.Script
    var rejectedPath: String? = nil
    var rejectedStatus = 200
    func makeStream(timeoutSeconds: Double) -> any SpeedTestStream { ScriptedTransfer(stats: stats, script: script) }
    func data(for request: URLRequest, timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
        let data = request.url!.path == "/meta" ? Data("{}".utf8) : Data()
        let status = request.url?.path == rejectedPath ? rejectedStatus : 200
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "\(data.count)"])!)
    }
}

private func drive<T: Sendable>(_ clock: MeasurementClock, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let complete = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
        defer { complete.withLock { $0 = true } }
        return try await operation()
    }
    for _ in 0..<2000 {
        if complete.withLock({ $0 }) { break }
        // Let every resumed worker register its next sleep before moving virtual time.
        for _ in 0..<20 { await Task.yield() }
        clock.advance(.milliseconds(50))
    }
    if !complete.withLock({ $0 }) { task.cancel(); Issue.record("virtual measurement did not finish") }
    return try await task.value
}

// Each upload fixture set occupies about 53 MiB. Keep independent test cases from
// allocating several sets simultaneously; each case still exercises concurrent streams.
@Suite("Speed test pipeline", .serialized, .timeLimit(.minutes(1)))
struct SpeedTestPipelineTests {
    @Test("Metadata and latency propagate HTTP refusals without inventing rate limits")
    func controlPhaseHTTPFailures() async {
        for path in ["/meta", "/__down"] {
            for status in [403, 429] {
                let stats = TransferStats()
                let transport = ScriptedTransport(stats: stats, script: { _, bytes, _ in
                    Issue.record("A failed control phase must not start throughput transfers")
                    return TransferReceipt(bytes: bytes, networkProtocol: nil)
                }, rejectedPath: path, rejectedStatus: status)
                let engine = CloudflareSpeedTest(time: SystemTimeSource(),
                    fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
                do { _ = try await engine.run { _ in }; Issue.record("Rejected control request must fail") }
                catch {
                    if status == 429 { #expect(error as? SpeedTestError == .rateLimited) }
                    else { #expect(error as? SpeedTestError == .refused(status: 403)) }
                }
                #expect(stats.value.withLock { $0.requests.isEmpty })
            }
        }
    }

    @Test("Concurrent reservations never exceed the shared data cap")
    func sharedBudget() async {
        let budget = PhaseByteBudget(ceiling: 3_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { while budget.reserve(preferredBytes: 1_048_576) != nil {} } }
        }
        #expect(budget.reservedBytes == 3_000_000)
        #expect(budget.isLimited)
    }

    @Test("Confirmed timelines retain arrival times and exclude provisional bytes")
    func confirmedTimeline() throws {
        let ledger = ConfirmedPayloadLedger()
        try ledger.confirm([TimedPayload(seconds: 1, bytes: 1_000_000), TimedPayload(seconds: 2, bytes: 2_000_000)], expectedBytes: 3_000_000)
        let summary = try ThroughputAggregator().summarize(ledger.slices(until: 5), totalBytes: ledger.bytes, totalSeconds: 5, incomplete: true)
        #expect(abs(summary.mbps - 16 / 3.5) < 0.001)
        #expect(summary.quality == .incomplete)
        #expect(throws: SpeedTestError.self) { try ledger.confirm([TimedPayload(seconds: 3, bytes: 5)], expectedBytes: 10) }
        #expect(ledger.bytes == 3_000_000)
    }

    @Test("The cap includes concurrent requests and produces an honest limited result")
    func phaseCap() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let transport = ScriptedTransport(stats: stats) { _, bytes, progress in
            try await clock.sleep(for: .seconds(3))
            progress(bytes)
            return TransferReceipt(bytes: bytes, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
        let result = try await drive(clock) {
            try await engine.runPhase(direction: .download, streams: 4, seconds: 10, ceiling: 47_918, progress: { _ in })
        }
        #expect(result.bytes == 47_918)
        #expect(stats.value.withLock { $0.requests.reduce(0, +) } == 47_918)
        #expect(result.summary.quality == .dataLimited)
        #expect(stats.value.withLock { $0.active } == 0)
    }

    @Test("Drain deadline cancels incomplete requests and includes drain time")
    func hardDrain() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let transport = ScriptedTransport(stats: stats) { call, bytes, progress in
            if call <= 2 {
                try await clock.sleep(for: .seconds(1))
                progress(bytes)
                return TransferReceipt(bytes: bytes, networkProtocol: "stub")
            }
            progress(bytes / 2)
            try await clock.sleep(for: .seconds(100))
            return TransferReceipt(bytes: bytes, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
        let result = try await drive(clock) {
            try await engine.runPhase(direction: .download, streams: 1, seconds: 3, ceiling: 100_000_000, progress: { _ in })
        }
        let requests = stats.value.withLock { $0.requests }
        #expect(requests.count == 3)
        #expect(result.bytes == UInt64(requests[0] + requests[1]))
        #expect(result.summary.quality == .incomplete)
        #expect(result.seconds >= 5 && result.seconds < 5.5)
        #expect(stats.value.withLock { $0.cancelled } == 1)
        #expect(stats.value.withLock { $0.active } == 0)
    }

    @Test("Chunk adaptation uses each stream's rate without dividing by the stream count")
    func perStreamAdaptation() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let transport = ScriptedTransport(stats: stats) { _, bytes, progress in
            try await clock.sleep(for: .seconds(1))
            progress(bytes)
            return TransferReceipt(bytes: bytes, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
        _ = try await drive(clock) {
            try await engine.runPhase(direction: .download, streams: 2, seconds: 3, ceiling: 100_000_000, progress: { _ in })
        }
        let requests = stats.value.withLock { $0.requests }
        #expect(requests.filter { $0 == 16_384 }.count == 2)
        #expect(requests.contains(32_768))
    }

    @Test("A rate limit aborts the phase and all sibling transfers")
    func rateLimitStopsAllStreams() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let transport = ScriptedTransport(stats: stats) { _, _, _ in
            try await clock.sleep(for: .seconds(0.2))
            throw SpeedTestError.rateLimited
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
        do {
            _ = try await drive(clock) { try await engine.runPhase(direction: .download, streams: 4, seconds: 10, ceiling: 100_000_000, progress: { _ in }) }
            Issue.record("rate-limited transfer must fail")
        } catch { #expect(error as? SpeedTestError == .rateLimited) }
        #expect(stats.value.withLock { $0.active } == 0)
    }

    @Test("Legacy history decodes without new methodology fields")
    func compatibleHistory() throws {
        let original = SpeedTestResult(engine: .cloudflare, startedAt: Date(timeIntervalSince1970: 0), downloadMbps: 10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpeedTestResult.self, from: data)
        #expect(decoded.methodologyVersion == nil)
        #expect(decoded.downloadQuality == nil)
        #expect(decoded.downloadMbps == 10)
    }

    @Test("A full run records only confirmed upload bytes and both direction qualities")
    func confirmedUploadResult() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let fixtures = UploadFixture(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { fixtures.clear() }
        try fixtures.prepare()
        let transport = ScriptedTransport(stats: stats) { _, bytes, progress in
            try await clock.sleep(for: .seconds(1.5))
            progress(bytes)
            return TransferReceipt(bytes: bytes, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: fixtures, transport: transport)
        var options = SpeedTestOptions()
        options.downloadStreams = 1
        options.uploadStreams = 1
        options.downloadSeconds = 5
        options.uploadSeconds = 5
        options.downloadByteCeiling = 32_768
        options.uploadByteCeiling = 32_768
        let savedOptions = options
        let result = try await drive(clock) { try await engine.run(options: savedOptions, progress: { _ in }) }
        #expect(result.uploadBytes == 32_768)
        #expect(result.uploadVerifiedBytes == result.uploadBytes)
        #expect(result.downloadBytes == 32_768)
        #expect(result.downloadQuality == "dataLimited")
        #expect(result.uploadQuality == "dataLimited")
        #expect(result.methodologyVersion == 2)
    }

    @Test("Sent upload bytes cannot survive missing server confirmation or receipt mismatch", arguments: [true, false])
    func rejectsUnconfirmedUpload(_ missingConfirmation: Bool) async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        let fixtures = UploadFixture(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { fixtures.clear() }
        try fixtures.prepare()
        let transport = ScriptedTransport(stats: stats) { _, bytes, progress in
            try await clock.sleep(for: .seconds(3))
            progress(bytes)
            if missingConfirmation { throw SpeedTestError.interception("server did not confirm uploaded bytes") }
            return TransferReceipt(bytes: bytes - 1, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: fixtures, transport: transport)
        do {
            _ = try await drive(clock) { try await engine.runPhase(direction: .upload, streams: 1, seconds: 5, ceiling: 16_384, progress: { _ in }) }
            Issue.record("unconfirmed upload must never produce a result")
        } catch { #expect(error is SpeedTestError) }
        #expect(stats.value.withLock { $0.active } == 0)
    }

    @Test("Upload budget uses only prepared rungs and leaves a tiny remainder unused")
    func boundedUploadFixtures() {
        let budget = PhaseByteBudget(ceiling: 100_000)
        var requests: [Int] = []
        while let bytes = budget.reserve(preferredBytes: 65_536, allowedSizes: UploadFixture.rungs) { requests.append(bytes) }
        #expect(requests.allSatisfy { UploadFixture.rungs.contains($0) })
        #expect(budget.reservedBytes <= 100_000)
        #expect(100_000 - budget.reservedBytes < 16_384)
        #expect(budget.isLimited)
    }

    @Test("Small first requests let a slow link produce a qualified measurement")
    func slowLink() async throws {
        let clock = MeasurementClock()
        let stats = TransferStats()
        // Six streams sharing 120 Kbps. The old six 1 MiB first requests could not
        // complete even one request before the 12-second hard deadline.
        let transport = ScriptedTransport(stats: stats) { _, bytes, progress in
            try await clock.sleep(for: .seconds(Double(bytes) * 8 / 20_000))
            progress(bytes)
            return TransferReceipt(bytes: bytes, networkProtocol: "stub")
        }
        let engine = CloudflareSpeedTest(time: clock, fixtures: UploadFixture(directory: FileManager.default.temporaryDirectory), transport: transport)
        let result = try await drive(clock) {
            try await engine.runPhase(direction: .download, streams: 6, seconds: 10, ceiling: 100_000_000, progress: { _ in })
        }
        #expect(result.bytes > 0)
        #expect(result.summary.mbps > 0 && result.summary.mbps.isFinite)
        #expect(result.summary.quality == .incomplete)
        #expect(result.seconds < 12.5)
    }
}
