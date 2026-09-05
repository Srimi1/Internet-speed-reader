import Foundation

/// Which measurement service produced, or will produce, a result.
///
/// Separate from `SpeedTestEngineID`, which is persisted in history and must keep exactly
/// its two cases: adding one there would make a 2.x history file undecodable by 1.x, and
/// the store moves a file it cannot decode aside wholesale.
public enum SpeedTestEngineKey: String, Sendable, Codable, CaseIterable {
    case cloudflareH3
    case cloudflareLegacy
    case apple

    /// The value written to history. Both Cloudflare hosts are the same provider.
    public var resultEngine: SpeedTestEngineID {
        switch self {
        case .cloudflareH3, .cloudflareLegacy: return .cloudflare
        case .apple: return .appleNetworkQuality
        }
    }

    public var displayName: String {
        switch self {
        case .cloudflareH3: return "Cloudflare"
        case .cloudflareLegacy: return "Cloudflare (classic)"
        case .apple: return "Apple networkQuality"
        }
    }
}

/// What the user picked in Settings.
public enum SpeedTestEngineChoice: String, Sendable, CaseIterable {
    case auto
    case cloudflareH3
    case cloudflareLegacy
    case apple

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// Engines to try, in order. Apple is last everywhere: it reaches whichever Apple
    /// endpoint it chooses, which can be far away, so it is a fallback rather than a
    /// like-for-like alternative.
    public var engineKeys: [SpeedTestEngineKey] {
        switch self {
        case .auto: return [.cloudflareH3, .cloudflareLegacy, .apple]
        case .cloudflareH3: return [.cloudflareH3]
        case .cloudflareLegacy: return [.cloudflareLegacy]
        case .apple: return [.apple]
        }
    }

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .cloudflareH3: return "Cloudflare"
        case .cloudflareLegacy: return "Cloudflare (classic)"
        case .apple: return "Apple networkQuality"
        }
    }
}

/// Everything an engine needs for one run.
public struct SpeedTestRequest: Sendable {
    public var interfaceName: String?
    public var cloudflareOptions: SpeedTestOptions
    public var appleMaxSeconds: Int
    /// "manual" or "scheduled", recorded with the result.
    public var trigger: String

    public init(
        interfaceName: String? = nil,
        cloudflareOptions: SpeedTestOptions = SpeedTestOptions(),
        appleMaxSeconds: Int = 15,
        trigger: String = "manual"
    ) {
        self.interfaceName = interfaceName
        self.cloudflareOptions = cloudflareOptions
        self.appleMaxSeconds = appleMaxSeconds
        self.trigger = trigger
    }
}

/// One measurement service the chain can try.
public protocol SpeedTestEngine: Sendable {
    var key: SpeedTestEngineKey { get }
    func run(_ request: SpeedTestRequest, progress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestResult
    /// Returns only once the engine's transport or subprocess has finished cleaning up.
    func cancel() async
}
