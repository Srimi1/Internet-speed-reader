import Foundation
import Network

/// An immutable, Sendable view of NWPath, so path state can cross isolation domains
/// and be constructed by hand in tests.
public struct PathSnapshot: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case satisfied, unsatisfied, requiresConnection, unknown
    }

    public struct Interface: Sendable, Equatable {
        public let name: String
        public let index: Int
        public let kind: Kind
        /// NWPath reports use by interface type, not by exact adapter. Same-type ties
        /// therefore retain the path's order rather than claiming precise route binding.
        public let isUsedByPath: Bool

        public init(name: String, index: Int, kind: Kind, isUsedByPath: Bool = false) {
            self.name = name
            self.index = index
            self.kind = kind
            self.isUsedByPath = isUsedByPath
        }

        public enum Kind: String, Sendable, Equatable {
            case wifi, wiredEthernet, cellular, loopback, tunnel, other

            /// A tunnel measures decrypted payload while the physical interface carries
            /// ciphertext, so the two are never summed and the UI says which is shown.
            public var isPhysical: Bool { self == .wifi || self == .wiredEthernet || self == .cellular }
        }
    }

    public let status: Status
    public let interfaces: [Interface]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let unsatisfiedReason: String?
    /// Increments on every meaningful change, so a speed test can detect that the
    /// network moved underneath it and abort rather than report a blended number.
    public let generation: Int

    public init(
        status: Status,
        interfaces: [Interface],
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        unsatisfiedReason: String? = nil,
        generation: Int = 0
    ) {
        self.status = status
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.unsatisfiedReason = unsatisfiedReason
        self.generation = generation
    }

    public static let unknown = PathSnapshot(status: .unknown, interfaces: [])

    public var activeInterface: Interface? {
        ActiveInterfaceSelector.select(from: interfaces)
    }
}

/// Picks the one interface whose counters the live meter reads.
public enum ActiveInterfaceSelector {
    /// Interfaces that carry traffic we must never count as internet throughput:
    /// loopback is our own traffic, awdl0/llw0 are Apple's peer-to-peer radios
    /// (AirDrop, AirPlay, Sidecar), and the rest are internal or bridge devices.
    public static let excludedNames: Set<String> = [
        "lo0", "awdl0", "llw0", "anpi0", "anpi1", "anpi2",
        "bridge0", "ap1", "gif0", "stf0",
    ]

    public static func select(from interfaces: [PathSnapshot.Interface]) -> PathSnapshot.Interface? {
        // NWPath reports one entry per address family, so en0 shows up twice.
        var seen = Set<Int>()
        let deduped = interfaces.filter { seen.insert($0.index).inserted }
            .filter { !excludedNames.contains($0.name) }

        // A physical interface always wins: with a VPN up, en0 carries the real
        // internet traffic and the tunnel would double-count it.
        if let physical = deduped.first(where: { $0.kind.isPhysical && $0.isUsedByPath })
            ?? deduped.first(where: { $0.kind.isPhysical }) {
            return physical
        }
        // Tunnel-only means a full-tunnel VPN, where the tunnel is the only place
        // the traffic is visible. The UI labels this as tunnel payload.
        return deduped.first(where: { $0.kind == .tunnel && $0.isUsedByPath })
            ?? deduped.first(where: { $0.kind == .tunnel }) ?? deduped.first
    }
}
