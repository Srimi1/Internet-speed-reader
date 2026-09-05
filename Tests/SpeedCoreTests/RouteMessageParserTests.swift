import Foundation
import Testing
@testable import SpeedCore

/// Builds synthetic NET_RT_IFLIST2 buffers so the walk can be tested without the kernel.
private struct MessageBuilder {
    var bytes: [UInt8] = []

    /// Appends a real if_msghdr2 record carrying the given counters.
    mutating func addInterface(index: Int, rx: UInt64, tx: UInt64, txPackets: UInt64 = 0) {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = UInt16(index)
        header.ifm_data.ifi_ibytes = rx
        header.ifm_data.ifi_obytes = tx
        header.ifm_data.ifi_opackets = txPackets
        append(&header, length: MemoryLayout<if_msghdr2>.size)
    }

    /// Appends a non-IFINFO2 record of an arbitrary length, which the walk must skip
    /// by ifm_msglen rather than by a fixed struct stride. The kernel never emits a
    /// message shorter than its own header, so neither does this.
    mutating func addOtherMessage(length requested: Int) {
        let length = max(requested, MemoryLayout<if_msghdr>.size)
        var header = if_msghdr()
        header.ifm_msglen = UInt16(length)
        header.ifm_type = UInt8(RTM_NEWADDR)
        append(&header, length: MemoryLayout<if_msghdr>.size)
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: max(0, length - MemoryLayout<if_msghdr>.size)))
    }

    /// A header claiming more bytes than actually follow.
    mutating func addTruncatedTail() {
        var header = if_msghdr()
        header.ifm_msglen = UInt16(4096)
        header.ifm_type = UInt8(RTM_IFINFO2)
        append(&header, length: MemoryLayout<if_msghdr>.size)
    }

    private mutating func append<T>(_ value: inout T, length: Int) {
        withUnsafeBytes(of: &value) { raw in
            bytes.append(contentsOf: raw.prefix(length))
        }
    }

    func parse(wantIndex: Int? = nil) -> [Int: IFCounters] {
        bytes.withUnsafeBytes { RouteMessageParser.parse($0, wantIndex: wantIndex) }
    }
}

@Suite("Route message parser")
struct RouteMessageParserTests {
    @Test("Reads 64-bit counters well above the 32-bit wrap point")
    func readsSixtyFourBitCounters() {
        var builder = MessageBuilder()
        // The exact value observed on the development machine, which the 32-bit API
        // under-reported by precisely 2^32.
        builder.addInterface(index: 11, rx: 6_082_856_020, tx: 1_805_371_232, txPackets: 5_000_000_000)

        let parsed = builder.parse()
        #expect(parsed[11]?.rx == 6_082_856_020)
        #expect(parsed[11]?.tx == 1_805_371_232)
        #expect(parsed[11]?.txPackets == 5_000_000_000)
        #expect(parsed[11]!.rx > UInt64(UInt32.max))
    }

    @Test("Skips foreign messages by ifm_msglen, including odd lengths")
    func advancesByMessageLength() {
        var builder = MessageBuilder()
        builder.addOtherMessage(length: 173)   // deliberately odd, forces misaligned offsets
        builder.addInterface(index: 4, rx: 1_000, tx: 2_000)
        builder.addOtherMessage(length: 129)
        builder.addInterface(index: 11, rx: 3_000, tx: 4_000)

        let parsed = builder.parse()
        #expect(parsed.count == 2)
        #expect(parsed[4] == IFCounters(rx: 1_000, tx: 2_000))
        #expect(parsed[11] == IFCounters(rx: 3_000, tx: 4_000))
    }

    @Test("A truncated trailing message is ignored, not crashed on")
    func toleratesTruncatedTail() {
        var builder = MessageBuilder()
        builder.addInterface(index: 11, rx: 42, tx: 43)
        builder.addTruncatedTail()

        let parsed = builder.parse()
        #expect(parsed == [11: IFCounters(rx: 42, tx: 43)])
    }

    @Test("Filtering by index returns only that interface")
    func filtersByIndex() {
        var builder = MessageBuilder()
        builder.addInterface(index: 1, rx: 10, tx: 10)
        builder.addInterface(index: 11, rx: 20, tx: 20)

        let parsed = builder.parse(wantIndex: 11)
        #expect(parsed.count == 1)
        #expect(parsed[11] == IFCounters(rx: 20, tx: 20))
    }

    @Test("A zero-length header stops the walk instead of looping forever")
    func zeroLengthStops() {
        var builder = MessageBuilder()
        builder.addInterface(index: 11, rx: 5, tx: 5)
        builder.bytes.append(contentsOf: [UInt8](repeating: 0, count: MemoryLayout<if_msghdr>.size))

        let parsed = builder.parse()
        #expect(parsed == [11: IFCounters(rx: 5, tx: 5)])
    }
}
