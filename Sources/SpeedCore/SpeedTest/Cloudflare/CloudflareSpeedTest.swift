import Foundation
import os

public struct SpeedTestOptions: Sendable {
    public var downloadStreams: Int = 6
    public var uploadStreams: Int = 4
    public var downloadSeconds: Double = 10
    public var uploadSeconds: Double = 8
    public var downloadByteCeiling: UInt64 = 1_610_612_736   // 1.5 GiB
    public var uploadByteCeiling: UInt64 = 1_073_741_824     // 1 GiB

    public init() {}

    public static let dataSaver: SpeedTestOptions = {
        var options = SpeedTestOptions()
        options.downloadSeconds = 5
        options.uploadSeconds = 4
        options.downloadByteCeiling = 209_715_200
        options.uploadByteCeiling = 104_857_600
        return options
    }()
}

/// The Cloudflare speed test.
///
/// Uses one URLSession per stream with `httpMaximumConnectionsPerHost = 1`, so N streams
/// really are N TCP connections. A single shared session would let URLSession coalesce
/// requests onto one connection if the host ever negotiates HTTP/2, which would quietly
/// turn a six-stream test into a one-stream test and under-report fast links.
public actor CloudflareSpeedTest {
    private let time: any TimeSource
    private let fixtures: UploadFixture
    private var progressHandler: (@Sendable (SpeedTestProgress) -> Void)?
    private var sessions: [URLSession] = []

    public init(time: any TimeSource = SystemTimeSource(), fixtures: UploadFixture? = nil) {
        self.time = time
        self.fixtures = fixtures ?? ((try? UploadFixture.makeDefault()) ?? UploadFixture(directory: FileManager.default.temporaryDirectory))
    }

    public static func makeSessionConfiguration(timeoutSeconds: Double) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = timeoutSeconds
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "identity",
            "User-Agent": "InternetSpeedReader/1.0 (macOS; +https://github.com/Srimi1/Internet-speed-reader)",
        ]
        return config
    }

    public func run(
        options: SpeedTestOptions = SpeedTestOptions(),
        interfaceName: String? = nil,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestResult {
        progressHandler = progress
        defer { teardownSessions() }

        let startedAt = time.wallClock()
        let runStart = time.now()

        var result = SpeedTestResult(engine: .cloudflare, startedAt: startedAt, interfaceName: interfaceName)

        // Metadata first: it is cheap, and knowing the ISP even if a later phase fails
        // is better than a blank result.
        progress(SpeedTestProgress(phase: .meta))
        let meta = await fetchMeta()
        result.ispName = meta?.ispDisplayName ?? "Unknown ISP"
        result.clientLocation = meta?.clientLocation
        result.serverName = meta?.serverDisplayName.map { "Cloudflare · \($0)" } ?? "Cloudflare"

        try Task.checkCancellation()

        // Latency.
        progress(SpeedTestProgress(phase: .latency))
        let latency = try await measureLatency()
        result.pingMs = latency.medianMs
        result.jitterMs = latency.jitterMs
        result.tcpMinRttMs = latency.tcpMinRttMs
        progress(SpeedTestProgress(phase: .latency, fraction: 0.2, pingMs: latency.medianMs))

        try Task.checkCancellation()

        // Download.
        let download = try await runDownloadPhase(options: options, progress: progress)
        result.downloadMbps = download.summary.mbps
        result.downloadMeanMbps = download.summary.meanMbps
        result.downloadPeakMbps = download.summary.peakMbps
        result.downloadBytes = download.bytes
        result.downloadSeconds = download.seconds
        result.downloadStreams = options.downloadStreams
        result.downloadChunkBytes = download.chunkBytes
        result.networkProtocol = download.networkProtocol
        result.quality = download.summary.quality.rawValue

        try Task.checkCancellation()

        // Upload.
        let upload = try await runUploadPhase(options: options, progress: progress)
        result.uploadMbps = upload.summary.mbps
        result.uploadMeanMbps = upload.summary.meanMbps
        result.uploadPeakMbps = upload.summary.peakMbps
        result.uploadBytes = upload.bytes
        result.uploadVerifiedBytes = upload.verifiedBytes
        result.uploadSeconds = upload.seconds
        result.uploadStreams = options.uploadStreams

        result.durationSeconds = time.now().seconds(since: runStart)
        progress(SpeedTestProgress(phase: .finishing, fraction: 1))
        return result
    }

    // MARK: Metadata

    private func fetchMeta() async -> CloudflareMeta? {
        let session = URLSession(configuration: Self.makeSessionConfiguration(timeoutSeconds: 5))
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await withDeadline(.seconds(4), clock: time) {
                let (data, response) = try await session.data(for: CloudflareEndpoints.metaRequest())
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return try? JSONDecoder().decode(CloudflareMeta.self, from: data)
            }
        } catch {
            Log.speedTest.info("meta lookup failed, ISP will fall back: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Latency

    struct LatencyMeasurement: Sendable {
        var medianMs: Double?
        var jitterMs: Double?
        var tcpMinRttMs: Double?
    }

    private func measureLatency(samples: Int = 20) async throws -> LatencyMeasurement {
        let session = URLSession(configuration: Self.makeSessionConfiguration(timeoutSeconds: 5))
        defer { session.finishTasksAndInvalidate() }

        var warm: [Double] = []
        var cold: [Double] = []
        var tcpMin: Double?
        let deadline = time.now().advanced(by: .seconds(6))

        for index in 0..<samples {
            if time.now() >= deadline { break }
            try Task.checkCancellation()

            var request = URLRequest(url: CloudflareEndpoints.download(bytes: 0, nonce: "l\(index)"))
            request.httpMethod = "GET"
            let started = time.now()
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }

            let roundTripMs = time.now().seconds(since: started) * 1000
            let timing = ServerTiming.parse(http.value(forHTTPHeaderField: "Server-Timing"))
            // Subtract the server's own processing time. A cold worker adds hundreds of
            // milliseconds that have nothing to do with the network.
            let networkMs = max(0, roundTripMs - timing.totalServerMs)

            if let minRtt = timing.tcpMinRttMs {
                tcpMin = min(tcpMin ?? minRtt, minRtt)
            }
            // The first request pays DNS, TCP and TLS setup, which is not latency.
            if index == 0 { cold.append(networkMs) } else { warm.append(networkMs) }
        }

        let usable = warm.count >= 5 ? warm : (warm + cold)
        guard !usable.isEmpty else {
            return LatencyMeasurement(medianMs: nil, jitterMs: nil, tcpMinRttMs: tcpMin)
        }

        let sorted = usable.sorted()
        let median = sorted.count % 2 == 0
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]

        var jitter: Double?
        if usable.count > 1 {
            let deltas = zip(usable.dropFirst(), usable).map { abs($0 - $1) }
            jitter = deltas.reduce(0, +) / Double(deltas.count)
        }

        return LatencyMeasurement(medianMs: median, jitterMs: jitter, tcpMinRttMs: tcpMin)
    }

    // MARK: Download

    struct PhaseOutcome: Sendable {
        var summary: ThroughputSummary
        var bytes: UInt64
        var seconds: Double
        var chunkBytes: Int
        var verifiedBytes: UInt64 = 0
        var networkProtocol: String?
    }

    private func runDownloadPhase(
        options: SpeedTestOptions,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> PhaseOutcome {
        progress(SpeedTestProgress(phase: .downloadProbe, fraction: 0.22))

        let ledger = ByteLedger()
        let probeRate = try await probeDownloadRate(ledger: ledger)
        let ladder = ChunkLadder()
        let perStream = max(probeRate / Double(options.downloadStreams), 0)
        let chunkBytes = ladder.size(forPerStreamBytesPerSecond: perStream)

        ledger.reset()
        let sampler = SliceSampler(ledger: ledger, time: time)
        let phaseStart = time.now()
        let deadline = phaseStart.advanced(by: .seconds(options.downloadSeconds))

        let protocolBox = OSAllocatedUnfairLock(initialState: String?.none)
        let interceptBox = OSAllocatedUnfairLock(initialState: String?.none)

        await sampler.start(phase: .download, ceiling: options.downloadByteCeiling, progress: progress)

        await withTaskGroup(of: Void.self) { group in
            for stream in 0..<options.downloadStreams {
                group.addTask { [time] in
                    let downloader = DownloadStream(
                        ledger: ledger,
                        timeoutSeconds: options.downloadSeconds + 5
                    )
                    defer { downloader.invalidate() }

                    var iteration = 0
                    while time.now() < deadline, !Task.isCancelled, ledger.bytes < options.downloadByteCeiling {
                        let url = CloudflareEndpoints.download(bytes: chunkBytes, nonce: "\(stream)-\(iteration)")
                        iteration += 1
                        let outcome = await downloader.fetch(url: url, requestedBytes: chunkBytes)

                        if let name = downloader.networkProtocolName {
                            protocolBox.withLock { $0 = name }
                        }
                        if case let .intercepted(reason) = outcome {
                            interceptBox.withLock { $0 = reason }
                            return
                        }
                    }
                }
            }
        }

        let slices = await sampler.stop()
        let seconds = time.now().seconds(since: phaseStart)

        if let reason = interceptBox.withLock({ $0 }) {
            throw SpeedTestError.interception(reason)
        }

        let summary = try summarize(slices: slices, bytes: ledger.bytes, seconds: seconds)
        return PhaseOutcome(
            summary: summary,
            bytes: ledger.bytes,
            seconds: seconds,
            chunkBytes: chunkBytes,
            networkProtocol: protocolBox.withLock { $0 }
        )
    }

    /// A short transfer to estimate the link rate, so the real phase can size its requests.
    private func probeDownloadRate(ledger: ByteLedger) async throws -> Double {
        let bytes = ChunkLadder.firstProbeBytes
        let downloader = DownloadStream(ledger: ledger, timeoutSeconds: 6)
        defer { downloader.invalidate() }

        let started = time.now()
        let outcome: ResponseValidation
        do {
            outcome = try await withDeadline(.seconds(5), clock: time) {
                await downloader.fetch(
                    url: CloudflareEndpoints.download(bytes: bytes, nonce: "probe"),
                    requestedBytes: bytes
                )
            }
        } catch {
            return 0
        }

        if case let .intercepted(reason) = outcome { throw SpeedTestError.interception(reason) }
        if outcome == .rateLimited { throw SpeedTestError.rateLimited }

        let seconds = max(time.now().seconds(since: started), 0.001)
        return Double(bytes) / seconds
    }

    // MARK: Upload

    private func runUploadPhase(
        options: SpeedTestOptions,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> PhaseOutcome {
        progress(SpeedTestProgress(phase: .uploadProbe, fraction: 0.62))

        let probeLedger = ByteLedger()
        let probeRate = await probeUploadRate(ledger: probeLedger)
        let perStream = max(probeRate / Double(options.uploadStreams), 0)
        let rung = fixtures.rung(forPerStreamBytesPerSecond: perStream)
        guard let fixtureURL = try? fixtures.url(forBytes: rung) else {
            throw SpeedTestError.engineFailure("could not prepare an upload body")
        }

        let ledger = ByteLedger()
        let sampler = SliceSampler(ledger: ledger, time: time)
        let phaseStart = time.now()
        let deadline = phaseStart.advanced(by: .seconds(options.uploadSeconds))
        let verified = OSAllocatedUnfairLock(initialState: UInt64(0))
        let interceptBox = OSAllocatedUnfairLock(initialState: String?.none)

        await sampler.start(phase: .upload, ceiling: options.uploadByteCeiling, progress: progress)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<options.uploadStreams {
                group.addTask { [time] in
                    let session = URLSession(
                        configuration: Self.makeSessionConfiguration(timeoutSeconds: options.uploadSeconds + 5)
                    )
                    defer { session.invalidateAndCancel() }

                    while time.now() < deadline, !Task.isCancelled, ledger.bytes < options.uploadByteCeiling {
                        var request = URLRequest(url: CloudflareEndpoints.upload)
                        request.httpMethod = "POST"
                        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        request.setValue("\(rung)", forHTTPHeaderField: "Content-Length")

                        let delegate = UploadStreamDelegate(ledger: ledger)
                        guard let (_, response) = try? await session.upload(
                            for: request, fromFile: fixtureURL, delegate: delegate
                        ) else { continue }

                        guard let http = response as? HTTPURLResponse else { continue }
                        let outcome = ResponseValidator.validateUpload(
                            status: http.statusCode,
                            confirmedBytesHeader: http.value(forHTTPHeaderField: "cf-meta-upload-bytes"),
                            sentBytes: rung
                        )
                        switch outcome {
                        case .valid:
                            verified.withLock { $0 &+= UInt64(rung) }
                        case let .intercepted(reason):
                            interceptBox.withLock { $0 = reason }
                            return
                        default:
                            break
                        }
                    }
                }
            }
        }

        let slices = await sampler.stop()
        let seconds = time.now().seconds(since: phaseStart)

        if let reason = interceptBox.withLock({ $0 }) {
            throw SpeedTestError.interception(reason)
        }

        let summary = try summarize(slices: slices, bytes: ledger.bytes, seconds: seconds)
        return PhaseOutcome(
            summary: summary,
            bytes: ledger.bytes,
            seconds: seconds,
            chunkBytes: rung,
            verifiedBytes: verified.withLock { $0 }
        )
    }

    private func probeUploadRate(ledger: ByteLedger) async -> Double {
        guard let url = try? fixtures.url(forBytes: UploadFixture.rungs[0]) else { return 0 }
        let session = URLSession(configuration: Self.makeSessionConfiguration(timeoutSeconds: 6))
        defer { session.invalidateAndCancel() }

        let request: URLRequest = {
            var request = URLRequest(url: CloudflareEndpoints.upload)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            return request
        }()

        let started = time.now()
        guard (try? await withDeadline(.seconds(5), clock: time, operation: {
            try await session.upload(for: request, fromFile: url, delegate: UploadStreamDelegate(ledger: ledger))
        })) != nil else { return 0 }

        let seconds = max(time.now().seconds(since: started), 0.001)
        return Double(UploadFixture.rungs[0]) / seconds
    }

    // MARK: Shared

    private func summarize(slices: [ThroughputSlice], bytes: UInt64, seconds: Double) throws -> ThroughputSummary {
        do {
            return try ThroughputAggregator().summarize(slices, totalBytes: bytes, totalSeconds: seconds)
        } catch {
            throw SpeedTestError.insufficientData
        }
    }

    private func teardownSessions() {
        sessions.forEach { $0.invalidateAndCancel() }
        sessions.removeAll()
    }
}

/// Samples the shared ledger every 100 ms to build the slice timeline.
actor SliceSampler {
    private let ledger: ByteLedger
    private let time: any TimeSource
    private var task: Task<Void, Never>?
    private var slices: [ThroughputSlice] = []

    init(ledger: ByteLedger, time: any TimeSource) {
        self.ledger = ledger
        self.time = time
    }

    func start(
        phase: SpeedTestPhase,
        ceiling: UInt64,
        progress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) {
        slices.removeAll()
        let start = time.now()
        task = Task { [weak self] in
            guard let self else { return }
            var previousBytes: UInt64 = 0
            var previousInstant = start

            while !Task.isCancelled {
                try? await self.time.sleep(for: .milliseconds(100), tolerance: .milliseconds(10))
                let now = self.time.now()
                let bytes = self.ledger.bytes
                let elapsed = now.seconds(since: previousInstant)
                guard elapsed > 0 else { continue }

                let mbps = Double(bytes &- previousBytes) * 8 / 1e6 / elapsed
                previousBytes = bytes
                previousInstant = now

                await self.append(ThroughputSlice(mbps: mbps, secondsSincePhaseStart: now.seconds(since: start)))
                progress(SpeedTestProgress(
                    phase: phase,
                    instantaneousMbps: mbps,
                    fraction: min(1, Double(bytes) / Double(max(ceiling / 8, 1)))
                ))
            }
        }
    }

    private func append(_ slice: ThroughputSlice) { slices.append(slice) }

    func stop() -> [ThroughputSlice] {
        task?.cancel()
        task = nil
        // Drop the final slice: it covers a partial interval after the streams stopped
        // and would drag the trimmed mean down.
        return slices.count > 1 ? Array(slices.dropLast()) : slices
    }
}
