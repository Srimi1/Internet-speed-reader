import Foundation
import Testing
@testable import SpeedCore

@Suite("Path change classifier")
struct PathChangeClassifierTests {
    private func snapshot(
        status: PathSnapshot.Status = .satisfied,
        interfaces: [PathSnapshot.Interface] = [wifi],
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        generation: Int = 1
    ) -> PathSnapshot {
        PathSnapshot(status: status, interfaces: interfaces, isExpensive: isExpensive,
                     isConstrained: isConstrained, generation: generation)
    }

    private static let wifi = PathSnapshot.Interface(name: "en0", index: 11, kind: .wifi, isUsedByPath: true)
    private static let ethernet = PathSnapshot.Interface(name: "en7", index: 14, kind: .wiredEthernet, isUsedByPath: true)
    private static let awdl = PathSnapshot.Interface(name: "awdl0", index: 17, kind: .other)
    private static let tunnel = PathSnapshot.Interface(name: "utun4", index: 21, kind: .tunnel)

    /// The common case: NWPath yields a new snapshot for a DNS or gateway change while the
    /// interface the meter reads is untouched. v1 treated this as a network change and
    /// blanked the readout several times an hour.
    @Test("A generation-only change is route-only")
    func generationOnlyIsRouteOnly() {
        let before = snapshot(generation: 4)
        let after = snapshot(generation: 5)
        #expect(PathChangeClassifier.classify(previous: before, current: after) == .routeOnly)
    }

    @Test("An identical snapshot is no change at all")
    func identicalIsNone() {
        let path = snapshot(generation: 7)
        #expect(PathChangeClassifier.classify(previous: path, current: path) == .none)
    }

    /// AirDrop, AirPlay and Sidecar bring up Apple's peer-to-peer radio. The selector
    /// already excludes it, so its arrival must not disturb the meter.
    @Test("Apple's peer-to-peer radio appearing is route-only")
    func awdlAppearanceIsRouteOnly() {
        let before = snapshot(generation: 1)
        let after = snapshot(interfaces: [Self.wifi, Self.awdl], generation: 2)
        #expect(PathChangeClassifier.classify(previous: before, current: after) == .routeOnly)
    }

    @Test("A VPN tunnel appearing changes the interface set")
    func tunnelAppearanceChangesInterfaceSet() {
        let before = snapshot(generation: 1)
        let after = snapshot(interfaces: [Self.wifi, Self.tunnel], generation: 2)
        #expect(PathChangeClassifier.classify(previous: before, current: after) == .interfaceSetChanged)
    }

    @Test("Moving from Wi-Fi to Ethernet changes the measured interface")
    func wifiToEthernetChangesActiveInterface() {
        let before = snapshot(generation: 1)
        let after = snapshot(interfaces: [Self.ethernet], generation: 2)
        #expect(PathChangeClassifier.classify(previous: before, current: after) == .activeInterfaceChanged)
    }

    @Test("Losing the network is a status change")
    func statusChange() {
        let before = snapshot(generation: 1)
        let after = snapshot(status: .unsatisfied, interfaces: [], generation: 2)
        #expect(PathChangeClassifier.classify(previous: before, current: after) == .statusChanged)
    }

    @Test("Becoming expensive or constrained is a cost change")
    func costChange() {
        let before = snapshot(generation: 1)
        #expect(PathChangeClassifier.classify(previous: before, current: snapshot(isExpensive: true, generation: 2)) == .costChanged)
        #expect(PathChangeClassifier.classify(previous: before, current: snapshot(isConstrained: true, generation: 2)) == .costChanged)
    }

    /// Only a genuine interface change may drop the sampler's baseline; every change ends
    /// a running capacity test, because one test must describe one network.
    @Test("Only interface changes rebind the meter, but any change ends a test")
    func consequences() {
        #expect(!PathChange.routeOnly.requiresInterfaceRebind)
        #expect(!PathChange.costChanged.requiresInterfaceRebind)
        #expect(!PathChange.interfaceSetChanged.requiresInterfaceRebind)
        #expect(PathChange.activeInterfaceChanged.requiresInterfaceRebind)
        #expect(PathChange.statusChanged.requiresInterfaceRebind)

        #expect(PathChange.routeOnly.invalidatesRunningTest)
        #expect(PathChange.activeInterfaceChanged.invalidatesRunningTest)
        #expect(!PathChange.none.invalidatesRunningTest)
    }
}
