import Foundation
import Network

public protocol PathSource: Sendable {
    /// Emits a snapshot on every meaningful change, starting with the current one.
    func snapshots() -> AsyncStream<PathSnapshot>
}

/// Wraps NWPathMonitor and converts NWPath into a Sendable snapshot.
public final class NWPathSource: PathSource {
    public init() {}

    public func snapshots() -> AsyncStream<PathSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.srimi.internetspeedreader.path")
            let counter = GenerationCounter()

            monitor.pathUpdateHandler = { path in
                guard let generation = counter.generationIfChanged(path) else { return }
                continuation.yield(Self.snapshot(from: path, generation: generation))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

    static func snapshot(from path: NWPath, generation: Int) -> PathSnapshot {
        let status: PathSnapshot.Status = switch path.status {
        case .satisfied: .satisfied
        case .unsatisfied: .unsatisfied
        case .requiresConnection: .requiresConnection
        @unknown default: .unknown
        }

        let interfaces = path.availableInterfaces.map { interface in
            PathSnapshot.Interface(
                name: interface.name,
                index: interface.index,
                kind: kind(for: interface),
                isUsedByPath: path.usesInterfaceType(interface.type)
            )
        }

        var reason: String?
        if path.status == .unsatisfied {
            reason = switch path.unsatisfiedReason {
            case .cellularDenied: "Cellular is off"
            case .wifiDenied: "Wi-Fi is off"
            case .localNetworkDenied: "Local network access denied"
            case .notAvailable: "No network available"
            default: "No network available"
            }
        }

        return PathSnapshot(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            unsatisfiedReason: reason,
            generation: generation
        )
    }

    private static func kind(for interface: NWInterface) -> PathSnapshot.Interface.Kind {
        switch interface.type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular: return .cellular
        case .loopback: return .loopback
        case .other:
            let name = interface.name
            let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
            return tunnelPrefixes.contains(where: name.hasPrefix) ? .tunnel : .other
        @unknown default: return .other
        }
    }
}

/// Thread-safe monotonic counter for path generations.
private final class GenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var previous: NWPath?

    func generationIfChanged(_ path: NWPath) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        // Native path equality also detects route changes that retain the same en0
        // interface. Deduplicate here so generation is a meaningful network identity.
        guard previous != path else { return nil }
        previous = path
        value += 1
        return value
    }
}
