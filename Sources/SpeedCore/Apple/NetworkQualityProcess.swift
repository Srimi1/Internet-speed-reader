import Foundation
import os

/// A completed child process, including the exit information needed to decide whether
/// its JSON can be trusted. Both output pipes have reached EOF before this is returned.
public struct NetworkQualityProcessOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let terminationStatus: Int32
    public let exitedNormally: Bool
    public let outputTruncated: Bool

    public init(
        stdout: Data, stderr: Data = Data(), terminationStatus: Int32 = 0,
        exitedNormally: Bool = true, outputTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.exitedNormally = exitedNormally
        self.outputTruncated = outputTruncated
    }
}

/// Injectable so deadline, cancellation, and corrupt-output tests never run a network test.
/// Instances are single use; `waitForExit` joins process termination and both pipe readers.
public protocol NetworkQualityProcess: Sendable {
    func start(arguments: [String]) throws
    func waitForExit() async -> NetworkQualityProcessOutput
    var isRunning: Bool { get }
    func terminate()
    func forceKill()
}

final class SystemNetworkQualityProcess: NetworkQualityProcess, @unchecked Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var readersFinished = 0
        var terminationStatus: Int32?
        var exitedNormally = false
        var waiter: CheckedContinuation<NetworkQualityProcessOutput, Never>?
    }

    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let outputLimit = 1_048_576

    init(executable: String = NetworkQualityRunner.executable) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start(arguments: [String]) throws {
        process.arguments = arguments
        process.terminationHandler = { [self] child in
            state.withLock {
                $0.terminationStatus = child.terminationStatus
                $0.exitedNormally = child.terminationReason == .exit
            }
            completeIfReady()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            throw error
        }
        // Reading only in terminationHandler deadlocks when either pipe fills before
        // the child exits. Drain independently while running, retaining bounded output.
        DispatchQueue.global(qos: .utility).async { [self] in drain(stdout.fileHandleForReading, isError: false) }
        DispatchQueue.global(qos: .utility).async { [self] in drain(stderr.fileHandleForReading, isError: true) }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func waitForExit() async -> NetworkQualityProcessOutput {
        await withCheckedContinuation { continuation in
            state.withLock { $0.waiter = continuation }
            completeIfReady()
        }
    }

    private func drain(_ handle: FileHandle, isError: Bool) {
        defer {
            try? handle.close()
            state.withLock { $0.readersFinished += 1 }
            completeIfReady()
        }
        do {
            while let data = try handle.read(upToCount: 16_384), !data.isEmpty {
                state.withLock { state in
                    let count = isError ? state.stderr.count : state.stdout.count
                    let room = max(0, outputLimit - count)
                    if data.count > room { state.truncated = true }
                    if isError { state.stderr.append(data.prefix(room)) }
                    else { state.stdout.append(data.prefix(room)) }
                }
            }
        } catch {
            // A read failure makes even syntactically valid JSON incomplete/untrusted.
            state.withLock { $0.truncated = true }
        }
    }

    private func completeIfReady() {
        let completion = state.withLock { state -> (CheckedContinuation<NetworkQualityProcessOutput, Never>, NetworkQualityProcessOutput)? in
            guard let status = state.terminationStatus, state.readersFinished == 2,
                  let waiter = state.waiter else { return nil }
            state.waiter = nil
            return (waiter, NetworkQualityProcessOutput(
                stdout: state.stdout, stderr: state.stderr, terminationStatus: status,
                exitedNormally: state.exitedNormally, outputTruncated: state.truncated
            ))
        }
        if let (waiter, output) = completion {
            // Release the termination callback's reference to this process wrapper.
            process.terminationHandler = nil
            waiter.resume(returning: output)
        }
    }
}
