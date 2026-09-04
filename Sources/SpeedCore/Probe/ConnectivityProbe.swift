import Foundation

public enum ProbeFailureKind: String, Sendable, Codable, Equatable {
    case notConnected
    case dnsFailed
    case timedOut
    case connectionLost
    case tlsFailed
    case deadline
    case badStatus
    case unknown

    public static func classify(_ error: Error) -> ProbeFailureKind {
        if error is DeadlineExceeded { return .deadline }
        guard let urlError = error as? URLError else { return .unknown }
        switch urlError.code {
        case .notConnectedToInternet: return .notConnected
        case .cannotFindHost, .dnsLookupFailed: return .dnsFailed
        case .timedOut: return .timedOut
        case .networkConnectionLost, .cannotConnectToHost: return .connectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted: return .tlsFailed
        default: return .unknown
        }
    }
}

public enum ProbeOutcome: Sendable, Equatable {
    case online(rttMs: Double?, viaFallback: Bool)
    /// Reached something, but it was not the internet: a portal answered instead.
    case captivePortal
    case offline(kind: ProbeFailureKind)

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

public protocol Prober: Sendable {
    func probe() async -> ProbeOutcome
}

/// Two-endpoint connectivity probe.
///
/// The primary is a 204 endpoint: an empty body and an unambiguous status code.
/// The fallback is Apple's captive-portal check over plain HTTP, whose body must
/// literally contain "Success". That body check is the captive-portal detector:
/// a portal returns its own 200 with different HTML, which a status-code-only
/// check would happily accept as "online".
public struct HTTPProber: Prober {
    public struct Endpoints: Sendable {
        public let primary: URL
        public let fallback: URL

        public static let `default` = Endpoints(
            primary: URL(string: "https://www.gstatic.com/generate_204")!,
            fallback: URL(string: "http://captive.apple.com/hotspot-detect.html")!
        )

        public init(primary: URL, fallback: URL) {
            self.primary = primary
            self.fallback = fallback
        }
    }

    /// The whole round shares one budget. Two independent timeouts would let a
    /// blackholed route take twice as long as the failure cadence allows.
    public static let roundBudget: Duration = .seconds(3)
    public static let primaryBudget: Duration = .milliseconds(1_500)

    private let session: URLSession
    private let endpoints: Endpoints
    private let time: any TimeSource

    public init(
        endpoints: Endpoints = .default,
        time: any TimeSource = SystemTimeSource(),
        session: URLSession? = nil
    ) {
        self.endpoints = endpoints
        self.time = time
        self.session = session ?? Self.makeSession()
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Every one of these matters. waitsForConnectivity would make the probe hang
        // waiting for a network instead of reporting that there isn't one, which is
        // the exact opposite of a connectivity probe's job.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
    }

    public func probe() async -> ProbeOutcome {
        let start = time.now()
        do {
            let rtt = try await withDeadline(Self.primaryBudget, clock: time) {
                try await Self.check204(session: session, url: endpoints.primary)
            }
            return .online(rttMs: rtt, viaFallback: false)
        } catch {
            // Primary failed. Spend whatever is left of the round budget on the fallback,
            // which also tells captive portals apart from real outages.
            let spent = time.now().seconds(since: start)
            let remaining = Self.roundBudget.seconds - spent
            guard remaining > 0.3 else {
                return .offline(kind: ProbeFailureKind.classify(error))
            }
            do {
                return try await withDeadline(.seconds(remaining), clock: time) {
                    try await Self.checkCaptive(session: session, url: endpoints.fallback)
                }
            } catch {
                return .offline(kind: ProbeFailureKind.classify(error))
            }
        }
    }

    private static func check204(session: URLSession, url: URL) async throws -> Double? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let started = ContinuousClock.now
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw URLError(.badServerResponse)
        }
        return ContinuousClock.now.seconds(since: started) * 1000
    }

    private static func checkCaptive(session: URLSession, url: URL) async throws -> ProbeOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = String(decoding: data, as: UTF8.self)

        if http.statusCode == 200, body.contains("Success") {
            return .online(rttMs: ContinuousClock.now.seconds(since: started) * 1000, viaFallback: true)
        }
        // Answered, but with something other than Apple's success page.
        return .captivePortal
    }
}
