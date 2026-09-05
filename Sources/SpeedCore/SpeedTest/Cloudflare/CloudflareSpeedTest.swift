import Foundation

public struct SpeedTestOptions: Sendable {
    public var downloadStreams: Int = 6
    public var uploadStreams: Int = 4
    public var downloadSeconds: Double = 10
    public var uploadSeconds: Double = 8
    public var downloadByteCeiling: UInt64 = 1_610_612_736
    public var uploadByteCeiling: UInt64 = 1_073_741_824

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

/// An on-demand capacity estimate against Cloudflare, with confirmed payload measured
/// on one shared clock. Live progress is provisional; only validated requests enter a result.
public actor CloudflareSpeedTest {
    public static let methodologyVersion = 2
    public static let drainSeconds: Double = 2
    private let time: any TimeSource
    private let fixtures: UploadFixture
    private let transport: any CloudflareTransport
    private let endpoints: CloudflareEndpoints
    private let ladder: ChunkLadder

    public init(
        time: any TimeSource = SystemTimeSource(),
        fixtures: UploadFixture? = nil,
        endpoints: CloudflareEndpoints = .h3
    ) {
        self.time = time
        self.fixtures = fixtures ?? ((try? UploadFixture.makeDefault()) ?? UploadFixture(directory: FileManager.default.temporaryDirectory))
        self.endpoints = endpoints
        self.transport = URLSessionCloudflareTransport(endpoints: endpoints)
        self.ladder = Self.makeLadder(for: endpoints)
    }

    init(
        time: any TimeSource,
        fixtures: UploadFixture,
        transport: any CloudflareTransport,
        endpoints: CloudflareEndpoints = .h3
    ) {
        self.time = time
        self.fixtures = fixtures
        self.transport = transport
        self.endpoints = endpoints
        self.ladder = Self.makeLadder(for: endpoints)
    }

    /// Only the legacy host has a known refused band; the other needs no special sizing.
    private static func makeLadder(for endpoints: CloudflareEndpoints) -> ChunkLadder {
        endpoints.key == .cloudflareLegacy ? ChunkLadder(refusedRange: ChunkLadder.refusedRange) : ChunkLadder()
    }

    /// The host this engine measures against, recorded with the result.
    public var endpointHost: String { endpoints.displayHost }

    public static func makeSessionConfiguration(timeoutSeconds: Double) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = false
        config.timeoutIntervalForRequest = min(10, timeoutSeconds)
        config.timeoutIntervalForResource = timeoutSeconds
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "identity",
            "User-Agent": "InternetSpeedReader/2.0 (macOS; +https://github.com/Srimi1/Internet-speed-reader)",
        ]
        return config
    }

    public func run(options: SpeedTestOptions = SpeedTestOptions(), interfaceName: String? = nil,
                    progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestResult {
        try validate(options)
        try Task.checkCancellation()
        let runStart = time.now()
        var result = SpeedTestResult(engine: .cloudflare, startedAt: time.wallClock(), interfaceName: interfaceName,
                                     methodologyVersion: Self.methodologyVersion,
                                     endpointHost: endpoints.displayHost, engineKey: endpoints.key.rawValue)

        progress(SpeedTestProgress(phase: .meta))
        Log.speedTest.info("Cloudflare phase meta started")
        let meta = try await fetchMeta()
        result.ispName = meta?.ispDisplayName ?? "Unknown ISP"
        result.clientLocation = meta?.clientLocation
        result.serverName = meta?.serverDisplayName.map { "Cloudflare · \($0)" } ?? "Cloudflare"

        progress(SpeedTestProgress(phase: .latency, fraction: 0.05))
        Log.speedTest.info("Cloudflare phase latency started")
        let latency = try await measureLatency()
        result.pingMs = latency.medianMs
        result.jitterMs = latency.jitterMs
        result.tcpMinRttMs = latency.tcpMinRttMs
        progress(SpeedTestProgress(phase: .latency, fraction: 0.2, pingMs: latency.medianMs))

        Log.speedTest.info("Cloudflare phase download started")
        let download = try await runPhase(direction: .download, streams: options.downloadStreams,
                                          seconds: options.downloadSeconds, ceiling: options.downloadByteCeiling, progress: progress)
        result.downloadMbps = download.summary.mbps
        result.downloadMeanMbps = download.summary.meanMbps
        result.downloadPeakMbps = download.summary.peakMbps
        result.downloadBytes = download.bytes
        result.downloadSeconds = download.seconds
        result.downloadStreams = options.downloadStreams
        result.downloadChunkBytes = download.chunkBytes
        result.downloadQuality = download.summary.quality.rawValue
        result.networkProtocol = download.networkProtocol

        try Task.checkCancellation()
        Log.speedTest.info("Cloudflare phase upload started")
        let upload = try await runPhase(direction: .upload, streams: options.uploadStreams,
                                        seconds: options.uploadSeconds, ceiling: options.uploadByteCeiling, progress: progress)
        try Task.checkCancellation()
        result.uploadMbps = upload.summary.mbps
        result.uploadMeanMbps = upload.summary.meanMbps
        result.uploadPeakMbps = upload.summary.peakMbps
        result.uploadBytes = upload.bytes
        result.uploadVerifiedBytes = upload.bytes
        result.uploadSeconds = upload.seconds
        result.uploadStreams = options.uploadStreams
        result.uploadQuality = upload.summary.quality.rawValue
        result.quality = (download.summary.quality.severity >= upload.summary.quality.severity
            ? download.summary.quality : upload.summary.quality).rawValue
        result.durationSeconds = time.now().seconds(since: runStart)
        progress(SpeedTestProgress(phase: .finishing, fraction: 1))
        Log.speedTest.info("Cloudflare run completed with validated download and upload results")
        return result
    }

    private func validate(_ options: SpeedTestOptions) throws {
        guard (1...16).contains(options.downloadStreams), (1...16).contains(options.uploadStreams),
              options.downloadSeconds.isFinite, options.uploadSeconds.isFinite,
              (2.5...60).contains(options.downloadSeconds), (2.5...60).contains(options.uploadSeconds),
              options.downloadByteCeiling > 0, options.uploadByteCeiling > 0 else {
            throw SpeedTestError.engineFailure("Invalid speed test duration, stream count or data budget")
        }
    }

    private func fetchMeta() async throws -> CloudflareMeta? {
        do {
            let transport = self.transport
            let request = endpoints.metaRequest()
            let (data, response) = try await withDeadline(.seconds(4), clock: time) {
                try await transport.data(for: request, timeoutSeconds: 4)
            }
            CloudflareResponseDiagnostics.record(response, phase: "meta")
            if response.statusCode == 429 { throw SpeedTestError.rateLimited }
            // A refusal here must let the chain try the next host, so it is not an
            // engine fault: metadata is the endpoint most likely to be header-gated.
            if response.statusCode == 403 { throw SpeedTestError.refused(status: 403) }
            guard response.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(CloudflareMeta.self, from: data)
        } catch {
            try Task.checkCancellation()
            if let failure = error as? SpeedTestError { throw failure }
            return nil
        }
    }

    struct LatencyMeasurement: Sendable {
        var medianMs: Double?
        var jitterMs: Double?
        var tcpMinRttMs: Double?
    }

    private func measureLatency(samples: Int = 20) async throws -> LatencyMeasurement {
        var warm: [Double] = []
        var firstSuccessful: Double?
        var tcpMin: Double?
        let deadline = time.now().advanced(by: .seconds(6))
        let nonce = UUID().uuidString
        for index in 0..<samples {
            try Task.checkCancellation()
            let remaining = deadline.seconds(since: time.now())
            guard remaining > 0 else { break }
            let request = endpoints.downloadRequest(bytes: 0, nonce: "\(nonce)-l\(index)")
            let started = time.now()
            do {
                let transport = self.transport
                let (data, http) = try await withDeadline(.seconds(remaining), clock: time) {
                    try await transport.data(for: request, timeoutSeconds: min(5, remaining))
                }
                CloudflareResponseDiagnostics.record(http, phase: "latency")
                try ResponseValidator.validateDownload(status: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    expectedContentLength: http.expectedContentLength, requestedBytes: 0).requireValid()
                try ResponseValidator.validateDownloadCompletion(receivedBytes: Int64(data.count), requestedBytes: 0).requireValid()
                let timing = ServerTiming.parse(http.value(forHTTPHeaderField: "Server-Timing"))
                let networkMs = max(0, time.now().seconds(since: started) * 1000 - timing.totalServerMs)
                if let minRtt = timing.tcpMinRttMs, minRtt.isFinite, minRtt >= 0 { tcpMin = min(tcpMin ?? minRtt, minRtt) }
                if firstSuccessful == nil { firstSuccessful = networkMs }
                else { warm.append(networkMs) }
            } catch {
                try Task.checkCancellation()
                if let failure = error as? SpeedTestError { throw failure }
                if error is DeadlineExceeded { break }
            }
        }
        // Never mix connection establishment into a number labelled as idle latency.
        guard warm.count >= 5 else { return LatencyMeasurement(medianMs: nil, jitterMs: nil, tcpMinRttMs: tcpMin) }
        let sorted = warm.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        let deltas = zip(warm.dropFirst(), warm).map { abs($0 - $1) }
        return LatencyMeasurement(medianMs: median, jitterMs: deltas.reduce(0, +) / Double(deltas.count), tcpMinRttMs: tcpMin)
    }

    enum Direction: Sendable { case download, upload }
    struct PhaseOutcome: Sendable {
        let summary: ThroughputSummary
        let bytes: UInt64
        let seconds: Double
        let chunkBytes: Int
        let networkProtocol: String?
    }

    /// The first request on each stream is its own probe, counted within the same time
    /// and byte budget. Subsequent sizes use that stream's measured rate, never rate/N.
    func runPhase(direction: Direction, streams: Int, seconds: Double, ceiling: UInt64,
                  progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> PhaseOutcome {
        try Task.checkCancellation()
        let time = self.time
        let transport = self.transport
        let fixtures = self.fixtures
        let ladder = self.ladder
        let uploadFiles: [Int: URL]
        if direction == .upload {
            progress(SpeedTestProgress(phase: .uploadProbe, fraction: 0.62))
            uploadFiles = try fixtures.prepare()
        } else { uploadFiles = [:] }
        let start = time.now()
        let cutoff = start.advanced(by: .seconds(seconds))
        let hardDeadline = cutoff.advanced(by: .seconds(Self.drainSeconds))
        let budget = PhaseByteBudget(ceiling: ceiling)
        let provisional = ByteLedger()
        let confirmed = ConfirmedPayloadLedger()
        let stop = PhaseStopState()
        let phase: SpeedTestPhase = direction == .download ? .download : .upload
        let baseFraction = direction == .download ? 0.22 : 0.62
        progress(SpeedTestProgress(phase: phase, fraction: baseFraction))
        let progressTask = Task {
            var previousBytes: UInt64 = 0
            var previousTime = start
            while !Task.isCancelled {
                do { try await time.sleep(for: .milliseconds(100), tolerance: .milliseconds(10)) }
                catch { return }
                guard !Task.isCancelled else { return }
                let now = time.now()
                let bytes = provisional.bytes
                let elapsed = now.seconds(since: previousTime)
                if elapsed > 0 {
                    progress(SpeedTestProgress(phase: phase, instantaneousMbps: Double(bytes - previousBytes) * 8 / 1e6 / elapsed,
                        fraction: baseFraction + 0.36 * min(1, now.seconds(since: start) / seconds)))
                }
                previousBytes = bytes
                previousTime = now
            }
        }

        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<streams {
                    group.addTask {
                        let stream = transport.makeStream(timeoutSeconds: seconds + Self.drainSeconds)
                        defer { stream.invalidate() }
                        var nextBytes = ChunkLadder.firstProbeBytes
                        while time.now() < cutoff {
                            if Task.isCancelled {
                                if stop.drainExpired { return false }
                                throw CancellationError()
                            }
                            // Upload uses only the finite prepared rung set. A final
                            // remainder below 16 KiB is left unused, never rounded up
                            // or cached as a new arbitrary fixture on every run.
                            guard let bytes = budget.reserve(preferredBytes: nextBytes,
                                allowedSizes: direction == .upload ? UploadFixture.rungs : nil) else { return false }
                            let timeline = RequestPayloadTimeline(time: time, phaseStart: start)
                            let requestStart = time.now()
                            let onBytes: @Sendable (Int) -> Void = { bytes in
                                timeline.record(bytes)
                                provisional.add(bytes)
                            }
                            do {
                                let receipt: TransferReceipt
                                if direction == .download {
                                    receipt = try await stream.download(bytes: bytes, nonce: UUID().uuidString, progress: onBytes)
                                } else {
                                    guard let file = uploadFiles[bytes] else { throw SpeedTestError.engineFailure("Missing prepared upload fixture") }
                                    receipt = try await stream.upload(bytes: bytes, file: file, progress: onBytes)
                                }
                                try Task.checkCancellation()
                                guard receipt.bytes == bytes else { throw SpeedTestError.engineFailure("Confirmed request size did not match its reservation") }
                                try confirmed.confirm(timeline.snapshot, expectedBytes: receipt.bytes)
                                stop.record(chunk: bytes, networkProtocol: receipt.networkProtocol)
                                let duration = time.now().seconds(since: requestStart)
                                if duration > 0 {
                                    let rate = Double(receipt.bytes) / duration
                                    nextBytes = direction == .download ? ladder.size(forPerStreamBytesPerSecond: rate)
                                        : fixtures.rung(forPerStreamBytesPerSecond: rate)
                                }
                            } catch is CancellationError {
                                if stop.drainExpired { stop.markIncomplete(); return false }
                                throw CancellationError()
                            }
                        }
                        return false
                    }
                }
                group.addTask {
                    // Keep Duration precision and recheck the actual deadline. A clock
                    // adapter rounding its sleep must not end the phase a fraction early.
                    while true {
                        let now = time.now()
                        guard now < hardDeadline else { break }
                        try await time.sleep(for: hardDeadline - now, tolerance: .zero)
                    }
                    stop.expireDrain()
                    return true
                }
                var unfinished = streams
                while unfinished > 0, let deadlineReached = try await group.next() {
                    if deadlineReached { group.cancelAll() }
                    else { unfinished -= 1 }
                }
                group.cancelAll()
            }
            let elapsed = time.now().seconds(since: start)
            progressTask.cancel()
            await progressTask.value
            try Task.checkCancellation()
            let summary: ThroughputSummary
            do {
                summary = try ThroughputAggregator().summarize(confirmed.slices(until: elapsed), totalBytes: confirmed.bytes,
                    totalSeconds: elapsed, dataLimited: budget.isLimited, incomplete: stop.incomplete)
            } catch { throw SpeedTestError.insufficientData }
            return PhaseOutcome(summary: summary, bytes: confirmed.bytes, seconds: elapsed,
                                chunkBytes: stop.largestChunk, networkProtocol: stop.networkProtocol)
        } catch {
            progressTask.cancel()
            await progressTask.value
            try Task.checkCancellation()
            if let urlError = error as? URLError, urlError.code == .timedOut { throw SpeedTestError.timeout(phase) }
            throw error
        }
    }
}
