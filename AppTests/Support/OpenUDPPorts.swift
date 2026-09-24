import Darwin

/// The UDP ports this process holds a bound socket on, read straight off its own file
/// descriptors, which is what `lsof -p` reads too.
///
/// It checks the whole process rather than one model on purpose: the unit test host is
/// the real app, and what matters is whether anything in it took the bulb port, not
/// whether one particular object says it did.
enum OpenUDPPorts {

    static func inThisProcess() -> Set<UInt16> {
        var ports = Set<UInt16>()
        let limit = min(getdtablesize(), 1 << 16)
        for descriptor in 0..<limit {
            guard isDatagramSocket(descriptor), let port = boundPort(descriptor) else {
                continue
            }
            ports.insert(port)
        }
        // A datagram socket nobody has bound yet reports port 0.
        ports.remove(0)
        return ports
    }

    private static func isDatagramSocket(_ descriptor: Int32) -> Bool {
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0 else {
            return false
        }
        return type == SOCK_DGRAM
    }

    private static func boundPort(_ descriptor: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
        default:
            return nil
        }
    }
}
