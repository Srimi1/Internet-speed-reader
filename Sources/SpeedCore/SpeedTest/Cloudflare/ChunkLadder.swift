import Foundation

/// Chooses how many bytes each request should ask for.
///
/// Sized from the PER-STREAM rate, never divided by the stream count. Dividing by N is a
/// classic mistake: it makes every request finish in a fraction of a second, so each
/// stream pays a full round trip of idle socket time between requests and fast links read
/// low. Two seconds of work per request keeps the connection saturated.
public struct ChunkLadder: Sendable {
    /// Cloudflare rejects anything above 50 MiB with a 403 whose body is one byte,
    /// which looks like a network failure if you are not expecting it.
    public static let maxBytes = 52_428_800
    public static let minBytes = 262_144
    public static let firstProbeBytes = 1_048_576
    public static let targetSecondsPerRequest: Double = 2.0

    public init() {}

    public func size(forPerStreamBytesPerSecond rate: Double) -> Int {
        guard rate > 0 else { return Self.firstProbeBytes }
        let target = rate * Self.targetSecondsPerRequest
        let rounded = Self.roundUpToPowerOfTwo(Int(target))
        return min(max(rounded, Self.minBytes), Self.maxBytes)
    }

    static func roundUpToPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }
}
