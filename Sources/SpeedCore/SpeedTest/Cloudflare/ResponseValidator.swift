import Foundation

public enum ResponseValidation: Sendable, Equatable {
    case valid
    /// Something answered, but not with the bytes we asked for. Never turn this into
    /// a number: a captive portal returning HTML would otherwise be measured as speed.
    case intercepted(reason: String)
    /// The server declined the request. Another endpoint may accept it, so the chain
    /// treats this differently from an engine fault.
    case refused(Int)
    case rateLimited
    case badStatus(Int)
}

public enum ResponseValidator {
    public static func validateDownload(
        status: Int,
        contentType: String?,
        expectedContentLength: Int64,
        requestedBytes: Int
    ) -> ResponseValidation {
        if status == 429 { return .rateLimited }
        // Any non-200 from the server itself is a refusal, including the 403 the legacy
        // host returns for certain byte counts when the browser headers are missing.
        guard status == 200 else { return .refused(status) }

        let mediaType = contentType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mediaType == "application/octet-stream" else {
            return .intercepted(reason: "unexpected content type \(contentType ?? "none")")
        }
        guard expectedContentLength == Int64(requestedBytes) else {
            return .intercepted(
                reason: "length mismatch: asked for \(requestedBytes), offered \(expectedContentLength)"
            )
        }
        return .valid
    }

    public static func validateUpload(
        status: Int,
        confirmedBytesHeader: String?,
        sentBytes: Int
    ) -> ResponseValidation {
        if status == 429 { return .rateLimited }
        guard status == 200 else { return .refused(status) }

        // The server echoes what it actually received, which is the only trustworthy
        // confirmation that the upload really happened.
        guard let raw = confirmedBytesHeader, let confirmed = Int(raw), confirmed > 0 else {
            return .intercepted(reason: "server did not confirm the uploaded byte count")
        }
        guard confirmed == sentBytes else {
            return .intercepted(reason: "server received \(confirmed) of \(sentBytes) bytes")
        }
        return .valid
    }

    /// Headers alone do not prove the body arrived: a reset after valid headers used
    /// to report success, including when no payload was delivered at all.
    public static func validateDownloadCompletion(receivedBytes: Int64, requestedBytes: Int) -> ResponseValidation {
        guard receivedBytes == Int64(requestedBytes) else {
            return .intercepted(reason: "received \(receivedBytes) of \(requestedBytes) download bytes")
        }
        return .valid
    }
}

extension ResponseValidation {
    func requireValid() throws {
        switch self {
        case .valid: return
        case .intercepted(let reason): throw SpeedTestError.interception(reason)
        case .rateLimited: throw SpeedTestError.rateLimited
        case .refused(let status): throw SpeedTestError.refused(status: status)
        case .badStatus(let status): throw SpeedTestError.engineFailure("Speed test server returned HTTP \(status)")
        }
    }
}

/// Diagnostic headers identify a rejected request without logging payloads, query
/// parameters, client addresses, or location metadata.
enum CloudflareResponseDiagnostics {
    static func record(_ response: HTTPURLResponse, phase: String, requestedBytes: Int = 0) {
        guard response.statusCode != 200 else { return }
        let endpoint = response.url?.path ?? "unknown"
        let retryAfter = String((response.value(forHTTPHeaderField: "Retry-After") ?? "none").prefix(128))
        let ray = String((response.value(forHTTPHeaderField: "CF-Ray") ?? "none").prefix(128))
        Log.speedTest.error("phase=\(phase, privacy: .public) endpoint=\(endpoint, privacy: .public) HTTP=\(response.statusCode) requestedBytes=\(requestedBytes) retryAfter=\(retryAfter, privacy: .public) cfRay=\(ray, privacy: .public)")
    }
}
