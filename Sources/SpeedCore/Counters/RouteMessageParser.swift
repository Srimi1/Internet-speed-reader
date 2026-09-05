import Foundation

/// Pure parser for the kernel's NET_RT_IFLIST2 route-message buffer.
///
/// Two rules make this correct, and both are easy to get wrong:
/// 1. Always advance by `ifm_msglen`, never by MemoryLayout<if_msghdr2>.size. The buffer
///    holds a mix of message types with different lengths, so a fixed stride desyncs.
/// 2. Use loadUnaligned. Route messages carry no alignment guarantee, and a plain load
///    is undefined behaviour on a misaligned address.
///
/// It reads if_data64 (64-bit counters) rather than the 32-bit if_data behind getifaddrs.
/// That is not a style preference: on the development machine en0's 32-bit receive counter
/// had already wrapped, reading exactly 2^32 lower than the truth.
public enum RouteMessageParser {
    public static func parse(
        _ buffer: UnsafeRawBufferPointer,
        wantIndex: Int? = nil
    ) -> [Int: IFCounters] {
        var result: [Int: IFCounters] = [:]
        let headerSize = MemoryLayout<if_msghdr>.size
        let header2Size = MemoryLayout<if_msghdr2>.size
        var offset = 0

        while offset + headerSize <= buffer.count {
            let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let messageLength = Int(header.ifm_msglen)

            // A zero or negative-looking length would loop forever; a length that runs past
            // the buffer means the tail is truncated.
            guard messageLength > 0, offset + messageLength <= buffer.count else { break }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + header2Size <= buffer.count {
                let header2 = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let index = Int(header2.ifm_index)
                if wantIndex == nil || wantIndex == index {
                    result[index] = IFCounters(
                        rx: header2.ifm_data.ifi_ibytes,
                        tx: header2.ifm_data.ifi_obytes,
                        txPackets: header2.ifm_data.ifi_opackets,
                        rxPackets: header2.ifm_data.ifi_ipackets
                    )
                }
            }

            offset += messageLength
        }

        return result
    }

    /// Interface name for an index, e.g. 11 -> "en0".
    public static func name(forIndex index: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func index(forName name: String) -> Int? {
        let index = if_nametoindex(name)
        return index == 0 ? nil : Int(index)
    }
}
