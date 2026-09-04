import Foundation

/// Decodes `networkQuality -c` output.
///
/// Every field is optional on purpose: the JSON schema changes between the default
/// parallel mode and sequential mode, where top-level `responsiveness` is replaced by
/// `dl_responsiveness` and `ul_responsiveness`. The binary is also undocumented, so
/// Apple can change keys in any point release; a missing field must degrade the
/// display rather than fail the decode.
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
