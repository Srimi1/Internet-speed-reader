import Foundation

public enum CloudflareEndpoints {
    public static let host = "https://speed.cloudflare.com"
    /// A Referer or Origin header is REQUIRED on /meta. Without one the endpoint
    /// answers 403 with an empty JSON object, which silently blanks the ISP display.
    public static let referer = "https://speed.cloudflare.com/"

    public static func download(bytes: Int, nonce: String) -> URL {
        URL(string: "\(host)/__down?bytes=\(bytes)&isr=\(nonce)")!
    }

    public static var upload: URL { URL(string: "\(host)/__up")! }
    public static var meta: URL { URL(string: "\(host)/meta")! }

    public static func metaRequest() -> URLRequest {
        var request = URLRequest(url: meta)
        request.httpMethod = "GET"
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }
}
