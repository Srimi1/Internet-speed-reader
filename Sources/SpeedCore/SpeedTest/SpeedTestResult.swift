import Foundation

public enum SpeedTestEngineID: String, Sendable, Codable {
    case cloudflare
    case appleNetworkQuality
}

/// Everything one run produced. Alternate statistics are stored alongside the headline
/// so a disputed number can be audited instead of argued about.
public struct SpeedTestResult: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var schemaVersion: Int
    public var engine: SpeedTestEngineID
    public var startedAt: Date
    public var durationSeconds: Double

    public var pingMs: Double?
    public var jitterMs: Double?
    public var tcpMinRttMs: Double?
    public var downloadLoadedLatencyMs: Double?
    public var uploadLoadedLatencyMs: Double?

    public var downloadMbps: Double?
    public var downloadMeanMbps: Double?
    public var downloadPeakMbps: Double?
    public var downloadBytes: UInt64
    public var downloadSeconds: Double
    public var downloadStreams: Int
    public var downloadChunkBytes: Int

    public var uploadMbps: Double?
    public var uploadMeanMbps: Double?
    public var uploadPeakMbps: Double?
    public var uploadBytes: UInt64
    public var uploadVerifiedBytes: UInt64
    public var uploadSeconds: Double
    public var uploadStreams: Int

    public var ispName: String?
    public var clientLocation: String?
    public var serverName: String?
    public var interfaceName: String?
    public var networkProtocol: String?
    public var quality: String?
    /// Nil identifies results saved by the original measurement engine.
    public var methodologyVersion: Int?
    public var downloadQuality: String?
    public var uploadQuality: String?
    /// Which host actually served the measurement, e.g. "h3.speed.cloudflare.com".
    /// Optional, like every field added after 1.0: a non-optional addition would make new
    /// history undecodable by an older build, which discards the whole file.
    public var endpointHost: String?
    /// The engine key, finer-grained than `engine`, which stays at its two stored cases.
    public var engineKey: String?
    /// Engines that refused before this one succeeded.
    public var fallbackFrom: [String]?
    /// "manual" or "scheduled".
    public var trigger: String?

    /// Apple's numbers live here and never mix with the Cloudflare columns.
    public var apple: AppleExtras?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 1,
        engine: SpeedTestEngineID,
        startedAt: Date,
        durationSeconds: Double = 0,
        pingMs: Double? = nil,
        jitterMs: Double? = nil,
        tcpMinRttMs: Double? = nil,
        downloadLoadedLatencyMs: Double? = nil,
        uploadLoadedLatencyMs: Double? = nil,
        downloadMbps: Double? = nil,
        downloadMeanMbps: Double? = nil,
        downloadPeakMbps: Double? = nil,
        downloadBytes: UInt64 = 0,
        downloadSeconds: Double = 0,
        downloadStreams: Int = 0,
        downloadChunkBytes: Int = 0,
        uploadMbps: Double? = nil,
        uploadMeanMbps: Double? = nil,
        uploadPeakMbps: Double? = nil,
        uploadBytes: UInt64 = 0,
        uploadVerifiedBytes: UInt64 = 0,
        uploadSeconds: Double = 0,
        uploadStreams: Int = 0,
        ispName: String? = nil,
        clientLocation: String? = nil,
        serverName: String? = nil,
        interfaceName: String? = nil,
        networkProtocol: String? = nil,
        quality: String? = nil,
        methodologyVersion: Int? = nil,
        downloadQuality: String? = nil,
        uploadQuality: String? = nil,
        endpointHost: String? = nil,
        engineKey: String? = nil,
        fallbackFrom: [String]? = nil,
        trigger: String? = nil,
        apple: AppleExtras? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.tcpMinRttMs = tcpMinRttMs
        self.downloadLoadedLatencyMs = downloadLoadedLatencyMs
        self.uploadLoadedLatencyMs = uploadLoadedLatencyMs
        self.downloadMbps = downloadMbps
        self.downloadMeanMbps = downloadMeanMbps
        self.downloadPeakMbps = downloadPeakMbps
        self.downloadBytes = downloadBytes
        self.downloadSeconds = downloadSeconds
        self.downloadStreams = downloadStreams
        self.downloadChunkBytes = downloadChunkBytes
        self.uploadMbps = uploadMbps
        self.uploadMeanMbps = uploadMeanMbps
        self.uploadPeakMbps = uploadPeakMbps
        self.uploadBytes = uploadBytes
        self.uploadVerifiedBytes = uploadVerifiedBytes
        self.uploadSeconds = uploadSeconds
        self.uploadStreams = uploadStreams
        self.ispName = ispName
        self.clientLocation = clientLocation
        self.serverName = serverName
        self.interfaceName = interfaceName
        self.networkProtocol = networkProtocol
        self.quality = quality
        self.methodologyVersion = methodologyVersion
        self.downloadQuality = downloadQuality
        self.uploadQuality = uploadQuality
        self.endpointHost = endpointHost
        self.engineKey = engineKey
        self.fallbackFrom = fallbackFrom
        self.trigger = trigger
        self.apple = apple
    }

    public var totalBytes: UInt64 { downloadBytes + uploadBytes }
}

public struct AppleExtras: Sendable, Codable, Equatable {
    public var baseRttMs: Double?
    public var responsivenessRPM: Double?
    public var downloadResponsivenessRPM: Double?
    public var uploadResponsivenessRPM: Double?
    public var testEndpoint: String?
    public var downloadFlows: Int?
    public var uploadFlows: Int?

    public init(
        baseRttMs: Double? = nil,
        responsivenessRPM: Double? = nil,
        downloadResponsivenessRPM: Double? = nil,
        uploadResponsivenessRPM: Double? = nil,
        testEndpoint: String? = nil,
        downloadFlows: Int? = nil,
        uploadFlows: Int? = nil
    ) {
        self.baseRttMs = baseRttMs
        self.responsivenessRPM = responsivenessRPM
        self.downloadResponsivenessRPM = downloadResponsivenessRPM
        self.uploadResponsivenessRPM = uploadResponsivenessRPM
        self.testEndpoint = testEndpoint
        self.downloadFlows = downloadFlows
        self.uploadFlows = uploadFlows
    }
}

public enum SpeedTestPhase: String, Sendable, Equatable, CaseIterable {
    case idle, meta, latency, downloadProbe, download, uploadProbe, upload, finishing

    /// Progress may only move forwards within one attempt. Lives here so the chain runner
    /// and the UI share one ordering instead of each keeping its own list.
    public var rank: Int {
        switch self {
        case .idle: return 0
        case .meta: return 1
        case .latency: return 2
        case .downloadProbe: return 3
        case .download: return 4
        case .uploadProbe: return 5
        case .upload: return 6
        case .finishing: return 7
        }
    }
}

public struct SpeedTestProgress: Sendable, Equatable {
    public let phase: SpeedTestPhase
    public let instantaneousMbps: Double
    public let fraction: Double
    public let pingMs: Double?
    /// Which engine attempt produced this update. A later attempt always supersedes an
    /// earlier one, even though it restarts at the first phase.
    public var attempt: Int
    /// Shown while the chain moves between engines, so a fallback is visible rather than
    /// looking like a stall.
    public var engineLabel: String?

    public init(
        phase: SpeedTestPhase,
        instantaneousMbps: Double = 0,
        fraction: Double = 0,
        pingMs: Double? = nil,
        attempt: Int = 0,
        engineLabel: String? = nil
    ) {
        self.phase = phase
        self.instantaneousMbps = instantaneousMbps
        self.fraction = fraction
        self.pingMs = pingMs
        self.attempt = attempt
        self.engineLabel = engineLabel
    }
}

public enum SpeedTestError: Error, Sendable, Equatable {
    case cancelled
    case offline
    case networkChanged
    case interception(String)
    /// The server answered, and declined. Distinct from an engine fault because another
    /// endpoint may well accept the same request.
    case refused(status: Int)
    case rateLimited
    case insufficientData
    case timeout(SpeedTestPhase)
    case engineFailure(String)
}
