import Darwin
import Foundation
import OSLog

/// The single UDP socket the whole package shares.
///
/// It binds the reply port (4002 in production) so that bulb replies land here, joins
/// the Govee multicast group, and is also used for every outbound datagram so that the
/// source port is 4002. Firmware on some Govee devices only replies to source port 4002.
public final class LANSocket: @unchecked Sendable {

    private let configuration: LANConfiguration
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.philwoolley.glowbeat.lansocket")
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "LANSocket")

    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var continuations: [UUID: AsyncStream<Datagram>.Continuation] = [:]
    private var port: UInt16 = 0
    private var hasStartedOnce = false
    /// Told about every datagram handed to the kernel, and whether `sendto` took it.
    /// Nil unless a diagnostic trace is running.
    private var sendObserver: SendObserver?
    private var sendObserverToken: UUID?

    /// One outbound datagram: what it was, where it went, and the `errno` when `sendto`
    /// refused it. Called on the socket's own queue, straight after the send.
    public typealias SendObserver = @Sendable (_ payload: Data,
                                               _ endpoint: LANEndpoint,
                                               _ failure: Int32?) -> Void

    public init(configuration: LANConfiguration = .production) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    /// The port actually bound, resolved after `start()`. Zero while stopped.
    public var boundPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { return }

        if !hasStartedOnce {
            hasStartedOnce = true
            warnIfTheReplyPortIsAlreadyHeld()
        }

        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard handle >= 0 else { throw LANSocketError.socketCreationFailed(errno) }

        do {
            try Self.setFlag(handle, SOL_SOCKET, SO_REUSEADDR, name: "SO_REUSEADDR")
            try Self.setFlag(handle, SOL_SOCKET, SO_REUSEPORT, name: "SO_REUSEPORT")
            guard fcntl(handle, F_SETFL, O_NONBLOCK) == 0 else {
                throw LANSocketError.optionFailed("O_NONBLOCK", errno)
            }
            try bindSocket(handle)
            if configuration.joinsMulticast {
                try joinMulticast(handle)
            }
        } catch {
            close(handle)
            throw error
        }

        descriptor = handle
        port = Self.readBoundPort(handle)

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(handle)
        }
        source.setCancelHandler {
            close(handle)
        }
        readSource = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = readSource
        readSource = nil
        descriptor = -1
        port = 0
        let finished = continuations
        continuations.removeAll()
        lock.unlock()

        source?.cancel()
        // Every removed continuation is finished, including when the socket was never
        // started, so a consumer's `for await` can never hang on a dead stream.
        for continuation in finished.values {
            continuation.finish()
        }
    }

    /// Reports every later outbound datagram to `observer`, replacing any observer
    /// already installed. Party Mode's opt-in trace installs one to count what actually
    /// leaves the Mac. Returns the token that removes it.
    @discardableResult
    public func addSendObserver(_ observer: @escaping SendObserver) -> UUID {
        let token = UUID()
        lock.lock()
        sendObserver = observer
        sendObserverToken = token
        lock.unlock()
        return token
    }

    /// Removes the observer `token` installed, and nothing else.
    public func removeSendObserver(_ token: UUID) {
        lock.lock()
        if sendObserverToken == token {
            sendObserver = nil
            sendObserverToken = nil
        }
        lock.unlock()
    }

    /// Whether an observer is installed. Read by the tests.
    public var hasSendObserver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sendObserver != nil
    }

    /// Fire and forget. UDP send failures are logged, never surfaced.
    public func send(_ payload: Data, to endpoint: LANEndpoint) {
        queue.async { [weak self] in
            self?.sendNow(payload, to: endpoint)
        }
    }

    /// One independent stream per subscriber. Discovery and the status poller each take one.
    public func makeDatagramStream() -> AsyncStream<Datagram> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    // MARK: Setup helpers

    /// Says out loud when something else already owns the reply port.
    ///
    /// The real socket sets `SO_REUSEPORT`, so a leftover Glowbeat process holding 4002
    /// does not make `bind` fail here. It makes the kernel hand each bulb reply to only
    /// one of the two sockets instead, and discovery in this process then reports zero
    /// bulbs with nothing in the log to explain it. A throwaway socket with none of the
    /// reuse options answers the question, because `bind` on that one does fail when the
    /// port is taken.
    ///
    /// Only ever run on the first start of this socket, never on a rebuild after a wake
    /// or a network change: `stop` closes the old descriptor on the read source's cancel
    /// handler, so on a restart this socket's own still closing descriptor would look
    /// exactly like a second process.
    private func warnIfTheReplyPortIsAlreadyHeld() {
        let replyPort = configuration.replyPort
        // Zero means bind an ephemeral port, which nothing else can be holding.
        guard replyPort != 0 else { return }

        let probe = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard probe >= 0 else { return }
        defer { close(probe) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = replyPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result != 0, errno == EADDRINUSE else { return }
        logger.warning("Another process holds UDP \(replyPort, privacy: .public); bulb replies may be stolen. Quit any other copy of Glowbeat.")
    }

    private static func setFlag(_ handle: Int32,
                                _ level: Int32,
                                _ option: Int32,
                                name: String) throws {
        var value: Int32 = 1
        guard setsockopt(handle, level, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw LANSocketError.optionFailed(name, errno)
        }
    }

    private func bindSocket(_ handle: Int32) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.replyPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw LANSocketError.bindFailed(errno) }
    }

    private func joinMulticast(_ handle: Int32) throws {
        guard let localAddress = LocalInterface.primaryIPv4Address() else {
            throw LANSocketError.noLocalIPv4Address
        }
        var request = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(configuration.multicastGroup)),
                              imr_interface: in_addr(s_addr: inet_addr(localAddress)))
        guard setsockopt(handle,
                         IPPROTO_IP,
                         IP_ADD_MEMBERSHIP,
                         &request,
                         socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            throw LANSocketError.optionFailed("IP_ADD_MEMBERSHIP", errno)
        }

        // Interface selection and TTL are best effort. A failure here still leaves a
        // usable socket, because discovery also unicasts the scan to known bulb IPs.
        var interface = in_addr(s_addr: inet_addr(localAddress))
        if setsockopt(handle,
                      IPPROTO_IP,
                      IP_MULTICAST_IF,
                      &interface,
                      socklen_t(MemoryLayout<in_addr>.size)) != 0 {
            logger.warning("IP_MULTICAST_IF failed with errno \(errno, privacy: .public)")
        }
        var ttl: UInt8 = 2
        if setsockopt(handle,
                      IPPROTO_IP,
                      IP_MULTICAST_TTL,
                      &ttl,
                      socklen_t(MemoryLayout<UInt8>.size)) != 0 {
            logger.warning("IP_MULTICAST_TTL failed with errno \(errno, privacy: .public)")
        }
    }

    private static func readBoundPort(_ handle: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    // MARK: Input and output

    private func drain(_ handle: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { storage in
                    storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(handle, raw.baseAddress, raw.count, 0, address, &fromLength)
                    }
                }
            }
            guard count > 0 else { return }
            guard let source = LANEndpoint(storage: from) else { continue }
            deliver(Datagram(source: source, payload: Data(buffer[0..<count])))
        }
    }

    private func deliver(_ datagram: Datagram) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(datagram)
        }
    }

    private func sendNow(_ payload: Data, to endpoint: LANEndpoint) {
        lock.lock()
        let handle = descriptor
        let observer = sendObserver
        lock.unlock()
        guard handle >= 0 else { return }

        guard var address = endpoint.socketAddress() else {
            // A malformed host would otherwise become 255.255.255.255 and broadcast this
            // command to every device on the network.
            logger.error("Skipping a send to the invalid host \(endpoint.host, privacy: .public)")
            return
        }
        let sent = payload.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(handle,
                           raw.baseAddress,
                           raw.count,
                           0,
                           $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let failure: Int32? = sent < 0 ? errno : nil
        if let failure {
            logger.debug("sendto \(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) failed with errno \(failure, privacy: .public)")
        }
        observer?(payload, endpoint, failure)
    }
}
