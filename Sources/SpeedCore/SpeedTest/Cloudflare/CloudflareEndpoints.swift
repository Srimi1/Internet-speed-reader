import Foundation

/// One Cloudflare speed-test host and the requests it accepts.
///
/// Injectable rather than a set of constants, so the app can move between hosts without
/// touching the transfer code, and so tests can assert what a request carries.
public struct CloudflareEndpoints: Sendable, Equatable {
    /// The host Cloudflare's own open-source measurement CLI targets by default. It
    /// negotiates HTTP/2, serves metadata without a browser header, and has none of the
    /// legacy host's refused byte ranges.
    public static let h3 = CloudflareEndpoints(host: "https://h3.speed.cloudflare.com", key: .cloudflareH3)
    /// The host behind the speed.cloudflare.com web page. Kept as an independent second
    /// path; it needs the browser headers below on every request.
    public static let legacy = CloudflareEndpoints(host: "https://speed.cloudflare.com", key: .cloudflareLegacy)

    public let host: String
    public let key: SpeedTestEngineKey

    public init(host: String, key: SpeedTestEngineKey) {
        self.host = host
        self.key = key
    }

    public var displayHost: String {
        URL(string: host)?.host() ?? host
    }

    public func download(bytes: Int, nonce: String) -> URL {
        URL(string: "\(host)/__down?bytes=\(bytes)&isr=\(nonce)")!
    }

    public var upload: URL { URL(string: "\(host)/__up")! }
    public var meta: URL { URL(string: "\(host)/meta")! }

    /// Every request carries a Referer and an Origin.
    ///
    /// The legacy host refuses a band of download sizes outright when neither header is
    /// present, and answers /meta with an empty document. That refusal is what made v1's
    /// larger requests fail with HTTP 403 while its smaller ones succeeded. The headers
    /// are harmless on the host that does not require them.
    private func browserHeaders(on request: inout URLRequest) {
        request.setValue("\(host)/", forHTTPHeaderField: "Referer")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    }

    public func metaRequest() -> URLRequest {
        var request = URLRequest(url: meta)
        request.httpMethod = "GET"
        browserHeaders(on: &request)
        return request
    }

    public func downloadRequest(bytes: Int, nonce: String) -> URLRequest {
        var request = URLRequest(url: download(bytes: bytes, nonce: nonce))
        request.httpMethod = "GET"
        browserHeaders(on: &request)
        return request
    }

    public func uploadRequest(bytes: Int) -> URLRequest {
        var request = URLRequest(url: upload)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(bytes)", forHTTPHeaderField: "Content-Length")
        browserHeaders(on: &request)
        return request
    }
}
