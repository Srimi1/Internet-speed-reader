import Foundation

/// Chooses how many bytes each request should ask for.
///
/// Sized from the PER-STREAM rate, never divided by the stream count. Dividing by N is a
/// classic mistake: it makes every request finish in a fraction of a second, so each
/// stream pays a full round trip of idle socket time between requests and fast links read
/// low. Two seconds of work per request keeps the connection saturated.
public struct ChunkLadder: Sendable {
    /// Conservative client ceiling retained after early larger requests were refused.
    /// This is not a published Cloudflare limit; later 16 MiB requests also received
    /// HTTP 403, whose cause remains unknown.
    public static let maxBytes = 52_428_800
    public static let minBytes = 16_384
    /// A 1 MiB first request on every stream cannot finish on a slow link before the
    /// drain deadline. Start small, then adapt from each connection's actual transfers.
    public static let firstProbeBytes = 16_384
    public static let targetSecondsPerRequest: Double = 2.0

    public init() {}

    public func size(forPerStreamBytesPerSecond rate: Double) -> Int {
        guard rate.isFinite, rate > 0 else { return Self.firstProbeBytes }
        let target = min(rate * Self.targetSecondsPerRequest, Double(Self.maxBytes))
        let rounded = Self.roundUpToPowerOfTwo(Int(target))
        return min(max(rounded, Self.minBytes), Self.maxBytes)
    }

    static func roundUpToPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }
}
