import Darwin
import XCTest
@testable import GoveeLAN

final class LANSocketTests: XCTestCase {

    /// Loopback only: no multicast, ephemeral reply port, so tests never touch the LAN.
    private func loopbackConfiguration() -> LANConfiguration {
        LANConfiguration(multicastGroup: "239.255.255.250",
                         scanPort: 4001,
                         replyPort: 0,
                         commandPort: .matchingReplySource,
                         joinsMulticast: false,
                         extraScanTargets: [])
    }

    func testStartBindsAnEphemeralPortWhenReplyPortIsZero() throws {
        let socket = LANSocket(configuration: loopbackConfiguration())
        try socket.start()
        defer { socket.stop() }
        XCTAssertGreaterThan(socket.boundPort, 0)
    }

    func testTwoSocketsExchangeADatagramOverLoopback() async throws {
        let listener = LANSocket(configuration: loopbackConfiguration())
        try listener.start()
        defer { listener.stop() }

        let sender = LANSocket(configuration: loopbackConfiguration())
        try sender.start()
        defer { sender.stop() }

        let stream = listener.makeDatagramStream()
        let destination = LANEndpoint(host: "127.0.0.1", port: listener.boundPort)
        let payload = try LANMessage.turn(on: true)

        let received = Task { () -> Datagram? in
            for await datagram in stream { return datagram }
            return nil
        }

        // UDP is lossy even on loopback under load, so send a few times.
        for _ in 0..<5 {
            sender.send(payload, to: destination)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let datagram = try await withThrowingTaskGroup(of: Datagram?.self) { group in
            group.addTask { await received.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let unwrapped = try XCTUnwrap(datagram, "No datagram arrived within 3 seconds.")
        XCTAssertEqual(unwrapped.payload, payload)
        XCTAssertEqual(unwrapped.source.host, "127.0.0.1")
        XCTAssertEqual(unwrapped.source.port, sender.boundPort)
    }

    /// The leftover process case from the hardware run: a stray Glowbeat holding UDP 4002
    /// with `SO_REUSEPORT` steals bulb replies. Starting must warn and carry on, never
    /// fail, because refusing to start would take a working app down over a stale one.
    func testStartStillSucceedsWhenAnotherReusePortSocketHoldsTheReplyPort() throws {
        let holder = try XCTUnwrap(SharedPortHolder(), "Could not bind a port to share.")
        defer { holder.close() }

        var configuration = loopbackConfiguration()
        configuration.replyPort = holder.port

        let socket = LANSocket(configuration: configuration)
        try socket.start()
        defer { socket.stop() }
        XCTAssertEqual(socket.boundPort, holder.port)
    }

    func testStopIsIdempotent() throws {
        let socket = LANSocket(configuration: loopbackConfiguration())
        try socket.start()
        socket.stop()
        socket.stop()
        XCTAssertEqual(socket.boundPort, 0)
    }

    func testStopEndsStreamsEvenWhenTheSocketWasNeverStarted() async throws {
        let socket = LANSocket(configuration: loopbackConfiguration())
        let stream = socket.makeDatagramStream()

        let drained = Task { () -> Bool in
            for await _ in stream {}
            return true
        }

        socket.stop()

        let ended = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await drained.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }

        // Without this a regression would hang the whole suite instead of failing here.
        drained.cancel()

        XCTAssertTrue(ended, "stop() must end every stream, even if the socket was never started.")
    }

    func testPrimaryIPv4AddressIsAnIPv4LiteralOrNil() throws {
        guard let address = LocalInterface.primaryIPv4Address() else {
            throw XCTSkip("This machine has no up, non loopback IPv4 interface.")
        }
        let parts = address.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true })
    }
}

/// A UDP socket holding an ephemeral port with the same reuse options `LANSocket` uses,
/// so a second socket can bind that port too and the two then split arriving datagrams.
private final class SharedPortHolder {

    let port: UInt16
    private let descriptor: Int32

    init?() {
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard handle >= 0 else { return nil }
        var enabled: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &enabled, size) == 0,
              setsockopt(handle, SOL_SOCKET, SO_REUSEPORT, &enabled, size) == 0 else {
            Darwin.close(handle)
            return nil
        }

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

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(handle)
            return nil
        }

        descriptor = handle
        port = UInt16(bigEndian: assigned.sin_port)
    }

    func close() {
        Darwin.close(descriptor)
    }
}

extension LANSocketTests {

    /// The trace counts what actually leaves the Mac through this, so it has to see every
    /// datagram, and a stale token must not be able to take a newer observer out.
    func testASendObserverSeesEveryDatagramAndOnlyItsTokenRemovesIt() async throws {
        let listener = LANSocket(configuration: loopbackConfiguration())
        try listener.start()
        defer { listener.stop() }
        let sender = LANSocket(configuration: loopbackConfiguration())
        try sender.start()
        defer { sender.stop() }
        let destination = LANEndpoint(host: "127.0.0.1", port: listener.boundPort)
        let box = SentBox()
        XCTAssertFalse(sender.hasSendObserver)

        let token = sender.addSendObserver { payload, endpoint, failure in
            box.append(payload.count, endpoint, failure)
        }
        sender.send(try LANMessage.turn(on: true), to: destination)
        sender.send(try LANMessage.devStatusRequest(), to: destination)
        let deadline = Date().addingTimeInterval(3)
        while box.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(box.count, 2)
        XCTAssertEqual(box.failures, 0)
        XCTAssertEqual(box.endpoints, [destination, destination])

        let replacement = sender.addSendObserver { _, _, _ in }
        sender.removeSendObserver(token)
        XCTAssertTrue(sender.hasSendObserver, "A stale token must not remove the newer observer.")
        sender.removeSendObserver(replacement)
        XCTAssertFalse(sender.hasSendObserver)
    }
}

private final class SentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(bytes: Int, endpoint: LANEndpoint, failure: Int32?)] = []

    func append(_ bytes: Int, _ endpoint: LANEndpoint, _ failure: Int32?) {
        lock.lock()
        entries.append((bytes, endpoint, failure))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.failure != nil }.count
    }

    var endpoints: [LANEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.endpoint)
    }
}
