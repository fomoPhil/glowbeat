import XCTest
import GoveeLANTestSupport
@testable import GoveeLAN

final class StatusPollerTests: XCTestCase {

    private func configuration(for bulbs: [FakeBulb]) -> LANConfiguration {
        LANConfiguration(replyPort: 0,
                         commandPort: .matchingReplySource,
                         joinsMulticast: false,
                         extraScanTargets: bulbs.map { $0.endpoint() })
    }

    /// Polls the box until `predicate` holds or the timeout expires, then returns the
    /// last snapshot so the caller can assert on it either way.
    private func waitForStatuses(_ box: StatusBox,
                                 timeout: TimeInterval = 4,
                                 until predicate: ([String: BulbState]) -> Bool) async throws
        -> [String: BulbState] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = box.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return box.snapshot()
    }

    /// Polls a fake bulb's recorded commands until `predicate` holds or the timeout
    /// expires, then returns the last snapshot so the caller can assert on it either way.
    private func waitForCommands(_ bulb: FakeBulb,
                                 timeout: TimeInterval = 4,
                                 until predicate: ([FakeBulb.Command]) -> Bool) async throws
        -> [FakeBulb.Command] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let commands = bulb.recordedCommands()
            if predicate(commands) { return commands }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return bulb.recordedCommands()
    }

    private func collect(_ statuses: AsyncStream<BulbStatusUpdate>, into box: StatusBox) -> Task<Void, Never> {
        Task {
            for await update in statuses {
                box.store(update.state, for: update.bulbID)
            }
        }
    }

    func testPollerPublishesStateForEachBulb() async throws {
        let first = try FakeBulb(deviceID: "AA:00")
        let second = try FakeBulb(deviceID: "BB:11")
        defer { first.stop(); second.stop() }

        first.applyExternalChange(BulbState(isOn: true,
                                            brightness: 20,
                                            color: GoveeRGB(r: 1, g: 0, b: 0),
                                            colorTemperatureKelvin: 0))
        second.applyExternalChange(BulbState(isOn: false,
                                             brightness: 70,
                                             color: GoveeRGB(r: 0, g: 2, b: 0),
                                             colorTemperatureKelvin: 0))

        let config = configuration(for: [first, second])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 0.1)
        let box = StatusBox()
        let collector = collect(poller.statuses, into: box)
        defer { collector.cancel() }

        let bulbs = [Bulb(id: "AA:00", sku: "H6004", endpoint: first.endpoint()),
                     Bulb(id: "BB:11", sku: "H6004", endpoint: second.endpoint())]
        await poller.start(bulbs: bulbs)
        defer { Task { await poller.stop() } }

        let result = try await waitForStatuses(box) { $0.count == 2 }
        XCTAssertEqual(result["AA:00"]?.brightness, 20)
        XCTAssertEqual(result["AA:00"]?.isOn, true)
        XCTAssertEqual(result["AA:00"]?.color, GoveeRGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(result["BB:11"]?.brightness, 70)
        XCTAssertEqual(result["BB:11"]?.isOn, false)
        XCTAssertEqual(result["BB:11"]?.color, GoveeRGB(r: 0, g: 2, b: 0))
    }

    func testUpdateBulbsChangesWhichBulbsArePolled() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 0.05)
        await poller.start(bulbs: [])
        defer { Task { await poller.stop() } }

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(fake.recordedCommands().isEmpty)

        await poller.updateBulbs([Bulb(id: "AA:00", sku: "H6004", endpoint: fake.endpoint())])
        let commands = try await waitForCommands(fake) { $0.contains(.devStatus) }
        XCTAssertTrue(commands.contains(.devStatus),
                      "The bulb never received devStatus after updateBulbs(_:).")
    }

    /// The poller is how the app learns that its own commands landed, so a bulb that was
    /// turned on, dimmed and recolored has to report all three back through `devStatus`.
    func testPollerPublishesStateLeftBehindByEarlierCommands() async throws {
        let fake = try FakeBulb(deviceID: "CC:22")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let bulb = Bulb(id: "CC:22", sku: "H6004", endpoint: fake.endpoint())
        let controller = BulbController(socket: socket,
                                        configuration: BulbController.Configuration(repeatCount: 3,
                                                                                    repeatInterval: 0.05))
        await controller.turn(true, bulbs: [bulb])
        await controller.setBrightness(42, bulbs: [bulb])
        await controller.setColor(GoveeRGB(r: 9, g: 8, b: 7), bulbs: [bulb])

        let poller = StatusPoller(socket: socket, configuration: config, interval: 0.1)
        let box = StatusBox()
        let collector = collect(poller.statuses, into: box)
        defer { collector.cancel() }

        await poller.start(bulbs: [bulb])
        defer { Task { await poller.stop() } }

        let expected = BulbState(isOn: true,
                                 brightness: 42,
                                 color: GoveeRGB(r: 9, g: 8, b: 7),
                                 colorTemperatureKelvin: 0)
        let result = try await waitForStatuses(box) { $0["CC:22"] == expected }
        XCTAssertEqual(result["CC:22"], expected)
    }

    /// The socket ends every datagram stream when it stops. Starting the poller again
    /// after the socket comes back has to arm a fresh receive loop, otherwise replies
    /// keep arriving on the socket and nothing is ever published.
    func testStartingAgainAfterTheSocketRestartsResumesPublishing() async throws {
        let fake = try FakeBulb(deviceID: "DD:33")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 0.1)
        let bulbs = [Bulb(id: "DD:33", sku: "H6004", endpoint: fake.endpoint())]
        // One collector for the whole test: `statuses` is a single consumer stream, and
        // canceling an iteration of it would terminate the stream for good.
        let box = StatusBox()
        let collector = collect(poller.statuses, into: box)
        defer { collector.cancel() }

        await poller.start(bulbs: bulbs)
        defer { Task { await poller.stop() } }

        let before = try await waitForStatuses(box) { $0["DD:33"] != nil }
        XCTAssertNotNil(before["DD:33"])

        socket.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        try socket.start()

        fake.applyExternalChange(BulbState(isOn: true,
                                           brightness: 55,
                                           color: GoveeRGB(r: 4, g: 5, b: 6),
                                           colorTemperatureKelvin: 0))

        await poller.start(bulbs: bulbs)
        let result = try await waitForStatuses(box) { $0["DD:33"]?.brightness == 55 }
        XCTAssertEqual(result["DD:33"]?.brightness, 55)
        XCTAssertEqual(result["DD:33"]?.isOn, true)
    }

    /// Party Mode drops the interval from 10 s to 1 s. The new cadence has to start now,
    /// not whenever the sleep that was already running happens to drain.
    func testSetIntervalRestartsTheCadenceInsteadOfWaitingOutTheCurrentSleep() async throws {
        let fake = try FakeBulb(deviceID: "EE:44")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 10)
        await poller.start(bulbs: [Bulb(id: "EE:44", sku: "H6004", endpoint: fake.endpoint())])
        defer { Task { await poller.stop() } }

        // `start(bulbs:)` polls once straight away. Clear that so only the new cadence counts.
        _ = try await waitForCommands(fake) { $0.contains(.devStatus) }
        fake.clearRecordedCommands()

        await poller.setInterval(0.05)
        let commands = try await waitForCommands(fake, timeout: 1) { $0.contains(.devStatus) }
        XCTAssertTrue(commands.contains(.devStatus),
                      "No devStatus arrived within 1 s of dropping the interval to 0.05 s.")
    }

    func testPollNowSendsDevStatusWithoutWaitingForTheNextTick() async throws {
        let fake = try FakeBulb(deviceID: "FF:55")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 10)
        await poller.start(bulbs: [Bulb(id: "FF:55", sku: "H6004", endpoint: fake.endpoint())])
        defer { Task { await poller.stop() } }

        _ = try await waitForCommands(fake) { $0.contains(.devStatus) }
        fake.clearRecordedCommands()

        await poller.pollNow()
        let commands = try await waitForCommands(fake, timeout: 1) { $0.contains(.devStatus) }
        XCTAssertTrue(commands.contains(.devStatus),
                      "pollNow() did not reach the bulb within 1 s.")
    }

    /// Settings can hand the same value back repeatedly. That must neither fire extra
    /// polls nor keep restarting the timer so that polls stop arriving.
    func testSettingAnUnchangedIntervalLeavesTheCadenceAlone() async throws {
        let fake = try FakeBulb(deviceID: "11:66")
        defer { fake.stop() }

        let config = configuration(for: [fake])
        let socket = LANSocket(configuration: config)
        try socket.start()
        defer { socket.stop() }

        let poller = StatusPoller(socket: socket, configuration: config, interval: 0.2)
        await poller.start(bulbs: [Bulb(id: "11:66", sku: "H6004", endpoint: fake.endpoint())])
        defer { Task { await poller.stop() } }

        try await Task.sleep(nanoseconds: 300_000_000)
        fake.clearRecordedCommands()

        // Ten redundant calls 50 ms apart, then 500 ms of quiet: about 1 s of polling at
        // 0.2 s, so roughly 5 requests. The calls are deliberately closer together than
        // the interval, which is what a dragged Settings slider looks like.
        for _ in 0..<10 {
            await poller.setInterval(0.2)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let count = fake.recordedCommands().filter { $0 == .devStatus }.count
        // Loopback, so the band only has to absorb scheduler jitter. Too many means the
        // redundant calls fired their own polls; too few means they starved the loop.
        XCTAssertGreaterThanOrEqual(count, 3, "The poll loop starved: only \(count) requests in ~1 s.")
        XCTAssertLessThanOrEqual(count, 8, "Redundant setInterval calls added polls: \(count) in ~1 s.")
    }
}

/// A tiny thread safe box so the collector task and the test body can share state.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: BulbState] = [:]

    func store(_ state: BulbState, for bulbID: String) {
        lock.lock()
        stored[bulbID] = state
        lock.unlock()
    }

    func snapshot() -> [String: BulbState] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
