import Foundation
import os
import Testing
@testable import SpeedCore

private let appleSuccess = Data(#"{"dl_throughput":80000000,"ul_throughput":20000000,"dl_bytes_transferred":10000000,"ul_bytes_transferred":2500000,"interface_name":"en0","test_endpoint":"example.test"}"#.utf8)

private final class AppleTestClock: TimeSource, Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State { var offset = Duration.zero; var waiters: [Waiter] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let origin = ContinuousClock.now
    let wallOrigin = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> ContinuousClock.Instant { origin.advanced(by: state.withLock { $0.offset }) }
    func wallClock() -> Date { wallOrigin.addingTimeInterval(state.withLock { $0.offset.seconds }) }
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func sleep(for duration: Duration, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { state in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { state.waiters.append(Waiter(id: id, deadline: state.offset + duration, continuation: continuation)) }
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(_ seconds: Double) {
        let ready = state.withLock { state in
            state.offset += .seconds(seconds)
            let ready = state.waiters.filter { $0.deadline <= state.offset }
            state.waiters.removeAll { $0.deadline <= state.offset }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private final class FakeAppleProcess: NetworkQualityProcess, Sendable {
    private struct State {
        var started = false
        var running = false
        var terminated = false
        var killed = false
        var arguments: [String] = []
        var output: NetworkQualityProcessOutput?
        var waiter: CheckedContinuation<NetworkQualityProcessOutput, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let initialOutput: NetworkQualityProcessOutput?
    private let terminateOutput: NetworkQualityProcessOutput?
    private let startFailure: Bool

    init(
        output: NetworkQualityProcessOutput? = nil,
        terminateOutput: NetworkQualityProcessOutput? = nil,
        startFailure: Bool = false
    ) {
        initialOutput = output
        self.terminateOutput = terminateOutput
        self.startFailure = startFailure
    }

    func start(arguments: [String]) throws {
        if startFailure { throw CocoaError(.fileNoSuchFile) }
        state.withLock { $0.started = true; $0.running = true; $0.arguments = arguments }
        if let initialOutput { finish(initialOutput) }
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var started: Bool { state.withLock { $0.started } }
    var terminated: Bool { state.withLock { $0.terminated } }
    var killed: Bool { state.withLock { $0.killed } }
    var arguments: [String] { state.withLock { $0.arguments } }

    func terminate() {
        state.withLock { $0.terminated = true }
        if let terminateOutput { finish(terminateOutput) }
    }

    func forceKill() {
        state.withLock { $0.killed = true }
        finish(NetworkQualityProcessOutput(stdout: Data(), terminationStatus: 9, exitedNormally: false))
    }

    func waitForExit() async -> NetworkQualityProcessOutput {
        await withCheckedContinuation { continuation in
            let output = state.withLock { state -> NetworkQualityProcessOutput? in
                if let output = state.output { return output }
                state.waiter = continuation
                return nil
            }
            if let output { continuation.resume(returning: output) }
        }
    }

    func finish(_ output: NetworkQualityProcessOutput) {
        let waiter = state.withLock { state in
            state.running = false
            state.output = output
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: output)
    }
}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@Suite("Apple Deep Test reliability", .timeLimit(.minutes(1)))
struct NetworkQualityRunnerTests {
    @Test("Successful output preserves Apple's bit units and injected elapsed time")
    func successfulOutput() async throws {
        let clock = AppleTestClock()
        let process = FakeAppleProcess()
        let runner = NetworkQualityRunner(time: clock, processFactory: { process })
        let task = Task { try await runner.run(interfaceName: "en7") }
        #expect(await eventually { process.started && clock.waiterCount == 1 })
        clock.advance(3.25)
        process.finish(NetworkQualityProcessOutput(stdout: appleSuccess))
        let result = try await task.value
        #expect(result.methodologyVersion == 2)
        #expect(result.downloadQuality == "good")
        #expect(result.uploadQuality == "good")
        #expect(result.downloadMbps == 80)
        #expect(result.uploadMbps == 20)
        #expect(result.downloadBytes == 10_000_000)
        #expect(result.uploadBytes == 2_500_000)
        #expect(result.durationSeconds == 3.25)
        #expect(result.startedAt == clock.wallOrigin)
        #expect(result.interfaceName == "en0")
        #expect(process.arguments == ["-c", "-s", "-M", "15", "-I", "en7"])
    }

    @Test("Nonzero and signalled exits cannot succeed even with valid JSON")
    func unsuccessfulExit() async {
        for output in [
            NetworkQualityProcessOutput(stdout: appleSuccess, terminationStatus: 1),
            NetworkQualityProcessOutput(stdout: appleSuccess, terminationStatus: 15, exitedNormally: false),
            NetworkQualityProcessOutput(stdout: appleSuccess, outputTruncated: true),
        ] {
            let process = FakeAppleProcess(output: output)
            let runner = NetworkQualityRunner(processFactory: { process })
            await #expect(throws: SpeedTestError.self) { try await runner.run() }
        }
    }

    @Test("Malformed, empty, missing-direction and zero-throughput reports fail")
    func unusableReports() async {
        for json in ["not json", "{}", #"{"dl_throughput":12}"#,
                     #"{"dl_throughput":0,"ul_throughput":10}"#,
                     #"{"dl_throughput":12,"ul_throughput":-1}"#] {
            let process = FakeAppleProcess(output: NetworkQualityProcessOutput(stdout: Data(json.utf8)))
            let runner = NetworkQualityRunner(processFactory: { process })
            await #expect(throws: SpeedTestError.self) { try await runner.run() }
        }
    }

    @Test("Impossible byte counts fail safely without integer conversion traps")
    func invalidByteCounts() throws {
        for bytes in [-1.0, .infinity, .nan, Double(UInt64.max), 2.5] {
            var report = try JSONDecoder().decode(NetworkQualityReport.self, from: appleSuccess)
            report.dl_bytes_transferred = bytes
            #expect(throws: SpeedTestError.self) { try report.validatedMeasurements() }
        }
        var report = try JSONDecoder().decode(NetworkQualityReport.self, from: appleSuccess)
        report.dl_bytes_transferred = 1e19
        report.ul_bytes_transferred = 1e19
        #expect(throws: SpeedTestError.self) { try report.validatedMeasurements() }
    }

    @Test("Nonfinite throughput cannot produce a completed report")
    func nonfiniteThroughput() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            var report = try JSONDecoder().decode(NetworkQualityReport.self, from: appleSuccess)
            report.ul_throughput = value
            #expect(throws: SpeedTestError.self) { try report.validatedMeasurements() }
        }
    }

    @Test("Missing optional diagnostics and byte counts preserve valid throughput")
    func optionalFields() throws {
        let report = try JSONDecoder().decode(NetworkQualityReport.self, from: Data(#"{"dl_throughput":12000000,"ul_throughput":3000000}"#.utf8))
        let measured = try report.validatedMeasurements()
        #expect(measured.downloadMbps == 12)
        #expect(measured.uploadMbps == 3)
        #expect(measured.downloadBytes == 0)
    }

    @Test("A deadline wins over valid JSON emitted in response to termination")
    func timeoutDoesNotBecomeSuccess() async {
        let clock = AppleTestClock()
        let process = FakeAppleProcess(terminateOutput: NetworkQualityProcessOutput(stdout: appleSuccess))
        let runner = NetworkQualityRunner(time: clock, processFactory: { process })
        let task = Task { try await runner.run(maxSeconds: 1) }
        #expect(await eventually { process.started && clock.waiterCount == 1 })
        clock.advance(11)
        await #expect(throws: SpeedTestError.timeout(.download)) { try await task.value }
        #expect(process.terminated)
        #expect(!process.isRunning)
    }

    @Test("Task cancellation kills an uncooperative child after two seconds and joins cleanup")
    func cancellationJoinsCleanup() async {
        let clock = AppleTestClock()
        let process = FakeAppleProcess()
        let runner = NetworkQualityRunner(time: clock, processFactory: { process })
        let task = Task { try await runner.run() }
        #expect(await eventually { process.started && clock.waiterCount == 1 })
        task.cancel()
        #expect(await eventually { process.terminated && clock.waiterCount == 2 })
        clock.advance(2)
        await #expect(throws: SpeedTestError.cancelled) { try await task.value }
        #expect(process.killed)
        #expect(!process.isRunning)
    }

    @Test("Explicit cancellation rejects immediate valid-looking output")
    func explicitCancellation() async {
        let process = FakeAppleProcess(terminateOutput: NetworkQualityProcessOutput(stdout: appleSuccess))
        let runner = NetworkQualityRunner(processFactory: { process })
        let task = Task { try await runner.run() }
        #expect(await eventually { process.started })
        await runner.cancel()
        await #expect(throws: SpeedTestError.cancelled) { try await task.value }
        #expect(!process.isRunning)
    }

    @Test("A concurrent run is rejected while the original process is active")
    func rejectsOverlap() async {
        let process = FakeAppleProcess(terminateOutput: NetworkQualityProcessOutput(stdout: appleSuccess))
        let runner = NetworkQualityRunner(processFactory: { process })
        let task = Task { try await runner.run() }
        #expect(await eventually { process.started })
        await #expect(throws: SpeedTestError.self) { try await runner.run() }
        await runner.cancel()
        _ = await task.result
    }

    @Test("Launch failure is reported and does not leave an active run")
    func launchFailure() async {
        let process = FakeAppleProcess(startFailure: true)
        let runner = NetworkQualityRunner(processFactory: { process })
        await #expect(throws: SpeedTestError.self) { try await runner.run() }
        await #expect(throws: SpeedTestError.self) { try await runner.run() }
        #expect(!process.isRunning)
    }

    @Test("The system adapter drains both pipes before process exit without network traffic")
    func drainsPipesWhileRunning() async throws {
        let process = SystemNetworkQualityProcess(executable: "/bin/sh")
        // Each output is four times the usual pipe capacity; waiting for termination
        // before reading either stream would deadlock this child.
        try process.start(arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2"])
        let output = await process.waitForExit()
        #expect(output.terminationStatus == 0)
        #expect(output.exitedNormally)
        #expect(output.stdout.count == 262_144)
        #expect(output.stderr.count == 262_144)
        #expect(!output.outputTruncated)
    }
}
