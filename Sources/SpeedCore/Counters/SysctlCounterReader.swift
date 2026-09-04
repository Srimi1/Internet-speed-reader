import Foundation

/// Reads per-interface byte counters through sysctl NET_RT_IFLIST2. No root required.
public struct SysctlCounterReader: CounterSource {
    public init() {}

    public func counters(forInterfaceIndex index: Int) -> IFCounters? {
        read(index: index)[index]
    }

    public func allCounters() -> [Int: IFCounters] {
        read(index: 0)
    }

    private func read(index: Int) -> [Int: IFCounters] {
        // mib[5] == 0 means "every interface"; a non-zero index asks the kernel to
        // return just that one, which is cheaper for the 1 Hz sampling loop.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]

        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return [:]
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }

        // ENOMEM means the table grew between the sizing call and the read; retry once.
        if status != 0 {
            guard errno == ENOMEM else { return [:] }
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
            buffer = [UInt8](repeating: 0, count: size)
            let retry = buffer.withUnsafeMutableBytes { raw -> Int32 in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
            }
            guard retry == 0 else { return [:] }
        }

        return buffer.withUnsafeBytes { raw in
            let limited = UnsafeRawBufferPointer(rebasing: raw[0..<min(size, raw.count)])
            return RouteMessageParser.parse(limited, wantIndex: index == 0 ? nil : index)
        }
    }
}
