import XCTest
import GoveeLANTestSupport
@testable import GoveeLAN

final class FakeBulbTests: XCTestCase {

    private func loopbackConfiguration(scanTarget: LANEndpoint) -> LANConfiguration {
        LANConfiguration(replyPort: 0,
                         commandPort: .matchingReplySource,
                         joinsMulticast: false,
                         extraScanTargets: [scanTarget])
    }

    /// Sends `payload` until `isSatisfied` returns true or the deadline passes.
    private func pump(_ socket: LANSocket,
                      payload: Data,
                      to endpoint: LANEndpoint,
                      until isSatisfied: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            socket.send(payload, to: endpoint)
            try await Task.sleep(nanoseconds: 30_000_000)
            if isSatisfied() { return }
        }
        XCTFail("FakeBulb did not respond within 3 seconds.")
    }

    func testFakeBulbAnswersAScanRequest() async throws {
        let bulb = try FakeBulb(deviceID: "AA:BB:CC:DD:EE:FF:00:11")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: loopbackConfiguration(scanTarget: bulb.endpoint()))
        try socket.start()
        defer { socket.stop() }

        let replies = ReplyBox()
        let stream = socket.makeDatagramStream()
        let reader = Task {
            for await datagram in stream {
                if case .scan(let reply)? = LANMessage.decode(datagram.payload) {
                    replies.store(reply)
                }
            }
        }
        defer { reader.cancel() }

        try await pump(socket,
                       payload: try LANMessage.scanRequest(),
                       to: bulb.endpoint()) { replies.value() != nil }

        let reply = try XCTUnwrap(replies.value())
        XCTAssertEqual(reply.device, "AA:BB:CC:DD:EE:FF:00:11")
        XCTAssertEqual(reply.sku, "H6004")
        XCTAssertEqual(reply.ip, "127.0.0.1")
    }

    func testFakeBulbAppliesCommandsAndRecordsThem() async throws {
        let bulb = try FakeBulb(deviceID: "AA:BB")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: loopbackConfiguration(scanTarget: bulb.endpoint()))
        try socket.start()
        defer { socket.stop() }

        try await pump(socket, payload: try LANMessage.turn(on: true), to: bulb.endpoint()) {
            bulb.currentState().isOn
        }
        try await pump(socket, payload: try LANMessage.brightness(42), to: bulb.endpoint()) {
            bulb.currentState().brightness == 42
        }
        try await pump(socket,
                       payload: try LANMessage.colorwc(rgb: GoveeRGB(r: 9, g: 8, b: 7)),
                       to: bulb.endpoint()) {
            bulb.currentState().color == GoveeRGB(r: 9, g: 8, b: 7)
        }

        let commands = bulb.recordedCommands()
        XCTAssertTrue(commands.contains(.turn(true)))
        XCTAssertTrue(commands.contains(.brightness(42)))
        XCTAssertTrue(commands.contains(.color(GoveeRGB(r: 9, g: 8, b: 7))))
    }

    func testFakeBulbStopsAnsweringScanWhenLANControlIsOff() async throws {
        let bulb = try FakeBulb(deviceID: "AA:BB")
        defer { bulb.stop() }
        bulb.setAnswersScan(false)

        let socket = LANSocket(configuration: loopbackConfiguration(scanTarget: bulb.endpoint()))
        try socket.start()
        defer { socket.stop() }

        let replies = ReplyBox()
        let stream = socket.makeDatagramStream()
        let reader = Task {
            for await datagram in stream {
                if case .scan(let reply)? = LANMessage.decode(datagram.payload) {
                    replies.store(reply)
                }
            }
        }
        defer { reader.cancel() }

        for _ in 0..<10 {
            socket.send(try LANMessage.scanRequest(), to: bulb.endpoint())
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNil(replies.value())
    }

    /// A real bulb on a busy network can miss a brightness command, or apply it a repeat
    /// late. A fake that hears it and keeps its old brightness is how a test says so.
    func testAFakeThatIsNotApplyingBrightnessRecordsItAndKeepsItsOwn() async throws {
        let bulb = try FakeBulb(deviceID: "AA:BB")
        defer { bulb.stop() }
        bulb.applyExternalChange(BulbState(isOn: true, brightness: 30,
                                           color: GoveeRGB(r: 1, g: 2, b: 3),
                                           colorTemperatureKelvin: 0))
        bulb.setAppliesBrightness(false)

        let socket = LANSocket(configuration: loopbackConfiguration(scanTarget: bulb.endpoint()))
        try socket.start()
        defer { socket.stop() }

        try await pump(socket, payload: try LANMessage.brightness(100), to: bulb.endpoint()) {
            bulb.recordedCommands().contains(.brightness(100))
        }
        XCTAssertEqual(bulb.currentState().brightness, 30, "The brightness was not applied.")

        bulb.setAppliesBrightness(true)
        try await pump(socket, payload: try LANMessage.brightness(100), to: bulb.endpoint()) {
            bulb.currentState().brightness == 100
        }
    }

    func testApplyExternalChangeMutatesStateWithoutRecordingACommand() {
        let bulb = try? FakeBulb(deviceID: "AA:BB")
        guard let bulb else { return XCTFail("FakeBulb failed to start.") }
        defer { bulb.stop() }

        bulb.applyExternalChange(BulbState(isOn: true,
                                           brightness: 12,
                                           color: GoveeRGB(r: 1, g: 2, b: 3),
                                           colorTemperatureKelvin: 0))
        XCTAssertEqual(bulb.currentState().brightness, 12)
        XCTAssertTrue(bulb.recordedCommands().isEmpty)
    }
}

/// A tiny thread safe box so the reader task and the test body can share a value.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScanReply?

    func store(_ reply: ScanReply) {
        lock.lock()
        stored = reply
        lock.unlock()
    }

    func value() -> ScanReply? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
