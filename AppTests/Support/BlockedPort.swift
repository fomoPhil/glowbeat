import Darwin

/// A plain UDP socket holding an ephemeral port with none of `LANSocket`'s reuse
/// options, so nothing else can bind that port while it lives.
final class BlockedPort {

    let port: UInt16
    private let descriptor: Int32

    init?() {
        let handle = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard handle >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(handle)
            return nil
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        descriptor = handle
        port = UInt16(bigEndian: actual.sin_port)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
