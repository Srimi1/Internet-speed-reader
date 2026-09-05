import Foundation

/// Decodes `networkQuality -c` output.
///
/// Every field is optional on purpose: the JSON schema changes between the default
/// parallel mode and sequential mode, where top-level `responsiveness` is replaced by
/// `dl_responsiveness` and `ul_responsiveness`. The binary is also undocumented, so
/// Apple can change keys in any point release. Decoding tolerates missing fields;
/// validation separately requires usable download and upload measurements before
/// declaring a completed test.
public struct NetworkQualityReport: Sendable, Codable {
    public var base_rtt: Double?
    public var dl_throughput: Double?
    public var ul_throughput: Double?
    public var dl_bytes_transferred: Double?
    public var ul_bytes_transferred: Double?
    public var dl_flows: Int?
    public var ul_flows: Int?
    public var responsiveness: Double?
    public var dl_responsiveness: Double?
    public var ul_responsiveness: Double?
    public var interface_name: String?
    public var test_endpoint: String?
    public var os_version: String?
    public var start_date: String?
    public var end_date: String?

    /// Throughput is reported in BITS per second. Dividing by 8 as if it were bytes
    /// would silently under-report by eight times.
    public var downloadMbps: Double? { dl_throughput.map { $0 / 1_000_000 } }
    public var uploadMbps: Double? { ul_throughput.map { $0 / 1_000_000 } }

    /// The dates are local time with no zone and no "T", so ISO8601DateFormatter fails.
    public static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: string)
    }
}

struct NetworkQualityMeasurements: Sendable, Equatable {
    let downloadMbps: Double
    let uploadMbps: Double
    let downloadBytes: UInt64
    let uploadBytes: UInt64
}

extension NetworkQualityReport {
    /// Optional diagnostics tolerate Apple's schema changes. A successful capacity
    /// test still needs both positive, finite throughput measurements; `{}` is not one.
    func validatedMeasurements() throws -> NetworkQualityMeasurements {
        guard let download = downloadMbps, download.isFinite, download > 0,
              let upload = uploadMbps, upload.isFinite, upload > 0 else {
            throw SpeedTestError.engineFailure("Apple Deep Test did not return usable download and upload measurements.")
        }
        let downloadBytes = try Self.validatedBytes(dl_bytes_transferred)
        let uploadBytes = try Self.validatedBytes(ul_bytes_transferred)
        guard !downloadBytes.addingReportingOverflow(uploadBytes).overflow else {
            throw SpeedTestError.engineFailure("Apple Deep Test returned an invalid byte count.")
        }
        return NetworkQualityMeasurements(
            downloadMbps: download, uploadMbps: upload,
            downloadBytes: downloadBytes, uploadBytes: uploadBytes
        )
    }

    private static func validatedBytes(_ value: Double?) throws -> UInt64 {
        guard let value else { return 0 }
        // Double(UInt64.max) rounds up to 2^64. The strict comparison prevents UInt64
        // conversion traps for that value, as well as negative or non-finite counts.
        guard value.isFinite, value >= 0, value < Double(UInt64.max),
              value.rounded(.towardZero) == value else {
            throw SpeedTestError.engineFailure("Apple Deep Test returned an invalid byte count.")
        }
        return UInt64(value)
    }
}
