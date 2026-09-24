import Darwin
import Foundation

/// Finds the Mac's own IPv4 address, needed to pick the interface for multicast.
public enum LocalInterface {

    /// Returns the first up, non loopback IPv4 address, preferring `en` interfaces
    /// (Wi-Fi and Ethernet) over anything else.
    public static func primaryIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, address: String)] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(socketAddress,
                                     socklen_t(socketAddress.pointee.sa_len),
                                     &host,
                                     socklen_t(host.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard status == 0 else { continue }
            let address = host.withUnsafeBufferPointer { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                return String(cString: base)
            }
            guard let address else { continue }
            candidates.append((String(cString: entry.pointee.ifa_name), address))
        }

        return candidates.first(where: { $0.name.hasPrefix("en") })?.address
            ?? candidates.first?.address
    }
}
