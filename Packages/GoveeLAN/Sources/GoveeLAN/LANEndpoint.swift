import Darwin
import Foundation

/// An IPv4 host and UDP port.
public struct LANEndpoint: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// One received UDP datagram and where it came from.
public struct Datagram: Hashable, Sendable {
    public var source: LANEndpoint
    public var payload: Data

    public init(source: LANEndpoint, payload: Data) {
        self.source = source
        self.payload = payload
    }
}

extension LANEndpoint {
    /// Builds an endpoint from a `recvfrom` source address. Returns nil for non IPv4.
    init?(storage: sockaddr_storage) {
        var copy = storage
        guard copy.ss_family == sa_family_t(AF_INET) else { return nil }
        let sin = withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
        var address = sin.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = buffer.withUnsafeMutableBufferPointer { output -> String? in
            guard let base = output.baseAddress,
                  inet_ntop(AF_INET, &address, base, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: base)
        }
        guard let host = converted else { return nil }
        self.init(host: host, port: UInt16(bigEndian: sin.sin_port))
    }

    /// Builds a `sockaddr_in` for `sendto`, or nil when the host is not an IPv4 literal.
    ///
    /// `inet_addr` answers INADDR_NONE for anything malformed, and INADDR_NONE is
    /// 255.255.255.255, so a single bad character in a host would quietly turn one
    /// bulb's command into a broadcast to every device on the network. `inet_pton`
    /// reports the failure instead, and the caller skips the send.
    func socketAddress() -> sockaddr_in? {
        guard let converted = Self.ipv4Address(host) else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = converted
        return address
    }

    /// True when `host` is a dotted quad IPv4 literal.
    public static func isValidIPv4(_ host: String) -> Bool {
        ipv4Address(host) != nil
    }

    static func ipv4Address(_ host: String) -> in_addr? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return address
    }
}
