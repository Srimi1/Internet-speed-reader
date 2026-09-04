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
}
