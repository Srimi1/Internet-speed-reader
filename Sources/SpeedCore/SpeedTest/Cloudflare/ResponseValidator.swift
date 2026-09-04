import Foundation

public enum ResponseValidation: Sendable, Equatable {
    case valid
    /// Something answered, but not with the bytes we asked for. Never turn this into
    /// a number: a captive portal returning HTML would otherwise be measured as speed.
    case intercepted(reason: String)
    /// Cloudflare's byte-cap rejection: a 403 whose body is a single byte.
    case byteCapExceeded
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
        if status == 403 {
            return expectedContentLength <= 1 ? .byteCapExceeded : .rateLimited
        }
        if status == 429 { return .rateLimited }
        guard status == 200 else { return .badStatus(status) }

        guard let contentType, contentType.hasPrefix("application/octet-stream") else {
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
        if status == 403 || status == 429 { return .rateLimited }
        guard status == 200 else { return .badStatus(status) }

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
}
