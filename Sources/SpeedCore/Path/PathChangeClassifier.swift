import Foundation

/// What actually changed between two path snapshots.
///
/// NWPath equality fails for DNS servers, gateways and address changes, so the monitor
/// yields a new snapshot — and a new generation — for events that leave the interface the
/// live meter reads completely untouched. Treating all of them as "the network changed"
/// blanked the readout and dropped the sampler's baseline several times an hour.
public enum PathChange: String, Sendable, Equatable {
    case none
    /// Same interfaces, same status: only the route details moved (DNS, gateway, DHCP
    /// renewal, a Wi-Fi roam that keeps the same adapter).
    case routeOnly
    /// Expensive or constrained flags moved, so a different network identity is in play.
    case costChanged
    /// An interface appeared or disappeared, for example a VPN tunnel coming up.
    case interfaceSetChanged
    /// The interface whose counters the meter reads is now a different one.
    case activeInterfaceChanged
    case statusChanged

    /// True when the live meter must drop its baseline and rebind.
    public var requiresInterfaceRebind: Bool {
        self == .activeInterfaceChanged || self == .statusChanged
    }

    /// True when a capacity test in flight can no longer be trusted to describe one
    /// network. A route change is enough: a test must never span two of them.
    public var invalidatesRunningTest: Bool { self != .none }
}

public enum PathChangeClassifier {
    public static func classify(previous: PathSnapshot, current: PathSnapshot) -> PathChange {
        if previous.status != current.status { return .statusChanged }

        let previousActive = previous.status == .satisfied ? previous.activeInterface : nil
        let currentActive = current.status == .satisfied ? current.activeInterface : nil
        if previousActive?.index != currentActive?.index || previousActive?.name != currentActive?.name {
            return .activeInterfaceChanged
        }

        // Compare only the interfaces the selector would ever consider, so Apple's
        // peer-to-peer radios appearing for AirDrop or Sidecar is not a network change.
        if considered(previous) != considered(current) { return .interfaceSetChanged }
        if previous.isExpensive != current.isExpensive || previous.isConstrained != current.isConstrained {
            return .costChanged
        }
        if previous.generation != current.generation { return .routeOnly }
        return .none
    }

    private static func considered(_ snapshot: PathSnapshot) -> Set<String> {
        var seen = Set<Int>()
        return Set(
            snapshot.interfaces
                .filter { seen.insert($0.index).inserted }
                .filter { !ActiveInterfaceSelector.excludedNames.contains($0.name) }
                .map { "\($0.index):\($0.name):\($0.kind.rawValue)" }
        )
    }
}
