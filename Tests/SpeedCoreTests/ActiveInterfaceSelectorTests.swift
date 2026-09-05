import Testing
@testable import SpeedCore

private func iface(_ name: String, _ index: Int, _ kind: PathSnapshot.Interface.Kind) -> PathSnapshot.Interface {
    PathSnapshot.Interface(name: name, index: index, kind: kind)
}

@Suite("Active interface selector")
struct ActiveInterfaceSelectorTests {
    @Test("Deduplicates the repeated entry NWPath reports per address family")
    func dedupes() {
        // Verified on the development machine: availableInterfaces returned en0 twice.
        let selected = ActiveInterfaceSelector.select(from: [
            iface("en0", 11, .wifi), iface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("A physical interface wins over a VPN tunnel, so bytes are never double counted")
    func physicalBeatsTunnel() {
        let selected = ActiveInterfaceSelector.select(from: [
            iface("utun4", 21, .tunnel), iface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("A full tunnel with no physical interface falls back to the tunnel")
    func tunnelOnly() {
        let selected = ActiveInterfaceSelector.select(from: [iface("utun4", 21, .tunnel)])
        #expect(selected?.name == "utun4")
        #expect(selected?.kind == .tunnel)
    }

    @Test("Apple peer-to-peer and loopback interfaces are never selected")
    func excludesPeerToPeer() {
        // awdl0 carried 34 MB of AirDrop traffic on an otherwise idle machine.
        let selected = ActiveInterfaceSelector.select(from: [
            iface("lo0", 1, .loopback), iface("awdl0", 15, .other), iface("llw0", 16, .other),
        ])
        #expect(selected == nil)
    }

    @Test("Wired Ethernet is preferred when it appears before Wi-Fi")
    func wiredCounts() {
        let selected = ActiveInterfaceSelector.select(from: [
            iface("en5", 14, .wiredEthernet), iface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en5")
    }

    @Test("An in-use physical type wins over a merely available adapter")
    func activePathTypeWins() {
        let selected = ActiveInterfaceSelector.select(from: [
            iface("en5", 14, .wiredEthernet),
            PathSnapshot.Interface(name: "en0", index: 11, kind: .wifi, isUsedByPath: true),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("Physical bytes are preferred even when a VPN is marked in use")
    func activeTunnelDoesNotDoubleCount() {
        let selected = ActiveInterfaceSelector.select(from: [
            PathSnapshot.Interface(name: "utun4", index: 21, kind: .tunnel, isUsedByPath: true),
            iface("en0", 11, .wifi),
        ])
        #expect(selected?.name == "en0")
    }

    @Test("Two adapters with the same active type retain deterministic path order")
    func sameTypeKeepsOrder() {
        let selected = ActiveInterfaceSelector.select(from: [
            PathSnapshot.Interface(name: "en5", index: 14, kind: .wiredEthernet, isUsedByPath: true),
            PathSnapshot.Interface(name: "en6", index: 15, kind: .wiredEthernet, isUsedByPath: true),
        ])
        #expect(selected?.name == "en5")
    }
}
