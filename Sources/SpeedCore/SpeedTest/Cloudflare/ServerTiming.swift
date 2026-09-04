import Foundation

/// Parses Cloudflare's Server-Timing headers.
///
/// The metric names matter: older write-ups mention `cfRequestDuration`, which no longer
/// exists. Today the edge reports `cfSpeedEdge` and `cfSpeedWorker`, and a cold worker can
/// add hundreds of milliseconds. Subtracting them is the difference between a ping that
/// reads 35 ms and one that reads 800 ms on the same link.
public struct ServerTiming: Sendable, Equatable {
    public var edgeMs: Double = 0
    public var workerMs: Double = 0
    /// Server-measured TCP round trip, from the cfL4 header, in milliseconds.
    public var tcpRttMs: Double?
    public var tcpMinRttMs: Double?

    public var totalServerMs: Double { edgeMs + workerMs }

    public init() {}

    /// `Server-Timing: cfSpeedEdge;dur=3, cfSpeedWorker;dur=22`
    /// plus a second header `cfL4;desc="?proto=TCP&rtt=30998&min_rtt=29701&..."` in µs.
    public static func parse(_ headerValue: String?) -> ServerTiming {
        var timing = ServerTiming()
        guard let headerValue else { return timing }

        for rawEntry in headerValue.split(separator: ",") {
            let entry = rawEntry.trimmingCharacters(in: .whitespaces)

            if entry.hasPrefix("cfSpeedEdge"), let value = duration(in: entry) {
                timing.edgeMs = value
            } else if entry.hasPrefix("cfSpeedWorker"), let value = duration(in: entry) {
                timing.workerMs = value
            } else if entry.hasPrefix("cfL4") {
                let parameters = l4Parameters(in: entry)
                // cfL4 reports microseconds.
                if let rtt = parameters["rtt"] { timing.tcpRttMs = rtt / 1000 }
                if let minRtt = parameters["min_rtt"] { timing.tcpMinRttMs = minRtt / 1000 }
            }
        }
        return timing
    }

    private static func duration(in entry: String) -> Double? {
        guard let range = entry.range(of: "dur=") else { return nil }
        let tail = entry[range.upperBound...]
        let number = tail.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    private static func l4Parameters(in entry: String) -> [String: Double] {
        guard let start = entry.firstIndex(of: "?") else { return [:] }
        let query = entry[entry.index(after: start)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        var result: [String: Double] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            result[String(parts[0])] = value
        }
        return result
    }
}
