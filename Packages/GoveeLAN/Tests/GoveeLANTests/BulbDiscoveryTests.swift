import XCTest
import GoveeLANTestSupport
@testable import GoveeLAN

final class BulbDiscoveryTests: XCTestCase {

    /// Tests that are not about the burst run it in milliseconds, so a round still closes
    /// at roughly the reply window and the timings below stay honest.
    private static let fastBurstSpacing: TimeInterval = 0.02

    private func configuration(for bulbs: [FakeBulb]) -> LANConfiguration {
        LANConfiguration(replyPort: 0,
                         commandPort: .matchingReplySource,
                         joinsMulticast: false,
                         extraScanTargets: bulbs.map { $0.endpoint() })
    }

    /// Repeatedly scans until `predicate` holds for the discovered list, or fails after 4 s.
    private func waitForBulbs(_ discovery: BulbDiscovery,
                              predicate: @escaping @Sendable ([Bulb]) -> Bool) async throws -> [Bulb] {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            await discovery.scanNow()
            try await Task.sleep(nanoseconds: 100_000_000)
            let bulbs = await discovery.currentBulbs()
            if predicate(bulbs) { return bulbs }
        }
        XCTFail("Discovery did not reach the expected state within 4 seconds.")
        return await discovery.currentBulbs()
    }

    private func scanCount(_ bulb: FakeBulb) -> Int {
        bulb.recordedCommands().filter { $0 == .scan }.count
    }

    func testDiscoveryFindsTwoFakeBulbsAndSortsThemByID() async throws {
        let first = try FakeBulb(deviceID: "AA:00")
        let second = try FakeBulb(deviceID: "BB:11")
        defer { first.stop(); second.stop() }

        let socket = LANSocket(configuration: configuration(for: [first, second]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [first, second]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        let bulbs = try await waitForBulbs(discovery) { $0.count == 2 }
        XCTAssertEqual(bulbs.map(\.id), ["AA:00", "BB:11"])
        XCTAssertEqual(bulbs[0].sku, "H6004")
        XCTAssertEqual(bulbs[0].endpoint, first.endpoint())
        XCTAssertEqual(bulbs[1].endpoint, second.endpoint())
        XCTAssertTrue(bulbs.allSatisfy(\.isReachable))
        XCTAssertEqual(bulbs[0].wifiVersionSoft, "1.01.27")
    }

    func testABulbIsMarkedUnreachableAfterThreeMissedScansAndIsNeverDeleted() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        _ = try await waitForBulbs(discovery) { $0.count == 1 && $0[0].isReachable }

        bulb.setAnswersScan(false)
        let afterSilence = try await waitForBulbs(discovery) { $0.first?.isReachable == false }
        XCTAssertEqual(afterSilence.count, 1)
        XCTAssertFalse(afterSilence[0].isReachable)

        bulb.setAnswersScan(true)
        let recovered = try await waitForBulbs(discovery) { $0.first?.isReachable == true }
        XCTAssertTrue(recovered[0].isReachable)
    }

    func testDiscoveryStoresStatusRepliesAgainstTheRightBulb() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }
        bulb.applyExternalChange(BulbState(isOn: true,
                                           brightness: 33,
                                           color: GoveeRGB(r: 4, g: 5, b: 6),
                                           colorTemperatureKelvin: 0))

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        _ = try await waitForBulbs(discovery) { $0.count == 1 }

        let deadline = Date().addingTimeInterval(3)
        var stored: BulbState?
        while Date() < deadline {
            socket.send(try LANMessage.devStatusRequest(), to: bulb.endpoint())
            try await Task.sleep(nanoseconds: 80_000_000)
            stored = await discovery.currentBulbs().first?.state
            if stored != nil { break }
        }
        XCTAssertEqual(stored?.brightness, 33)
        XCTAssertEqual(stored?.color, GoveeRGB(r: 4, g: 5, b: 6))
    }

    func testUpdatesStreamPublishesSnapshots() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        let updates = discovery.updates
        await discovery.start()
        defer { Task { await discovery.stop() } }

        let observer = Task { () -> [Bulb] in
            for await snapshot in updates where !snapshot.isEmpty {
                return snapshot
            }
            return []
        }

        _ = try await waitForBulbs(discovery) { $0.count == 1 }
        let snapshot = await observer.value
        XCTAssertEqual(snapshot.first?.id, "AA:00")
    }

    /// The datagram stream ends whenever the socket stops, for example when the Mac
    /// changes network. Discovery has to pick up again on the next `start()`.
    func testStartResumesReceivingAfterTheDatagramStreamEnds() async throws {
        let first = try FakeBulb(deviceID: "AA:00")
        let second = try FakeBulb(deviceID: "BB:11")
        defer { first.stop(); second.stop() }
        // The second bulb stays silent until after the restart, so discovering it proves
        // the restarted receive loop is the one doing the work.
        second.setAnswersScan(false)

        let socket = LANSocket(configuration: configuration(for: [first, second]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [first, second]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        _ = try await waitForBulbs(discovery) { $0.count == 1 }

        socket.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        try socket.start()
        second.setAnswersScan(true)
        await discovery.start()

        let bulbs = try await waitForBulbs(discovery) { $0.count == 2 }
        XCTAssertEqual(bulbs.map(\.id), ["AA:00", "BB:11"])
        XCTAssertTrue(bulbs.allSatisfy(\.isReachable))
    }

    /// Tapping "Scan now" several times in a row must not stack misses onto a bulb that
    /// simply has not had time to answer yet.
    func testRapidScansDoNotStackMissesButRealMissesStillCount() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        _ = try await waitForBulbs(discovery) { $0.count == 1 && $0[0].isReachable }

        bulb.setAnswersScan(false)
        for _ in 0..<5 {
            await discovery.scanNow()
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let afterTaps = await discovery.currentBulbs()
        XCTAssertEqual(afterTaps.count, 1)
        XCTAssertEqual(afterTaps.first?.isReachable, true)

        // Misses spread over real rounds still take the bulb offline.
        let afterSilence = try await waitForBulbs(discovery) { $0.first?.isReachable == false }
        XCTAssertEqual(afterSilence.first?.isReachable, false)
    }

    /// One scan round sends the request three times, because Wi-Fi drops multicast and a
    /// single send missed real bulbs.
    func testOneScanRoundSendsTheScanThreeTimes() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        // Deliberately not started: only the one explicit round may send anything.
        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: 0.05)
        defer { Task { await discovery.stop() } }

        await discovery.scanNow()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(scanCount(bulb), 3)
    }

    /// A bulb whose first two replies are lost still counts as seen for that round, so the
    /// round must not charge it a miss.
    func testABulbThatAnswersOnlyTheThirdScanOfABurstIsNotMissed() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        // One miss is enough to go unreachable, so any miss charged during the burst shows.
        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 1,
                                      scanRepeatSpacing: 0.3)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        let deadline = Date().addingTimeInterval(3)
        while await discovery.currentBulbs().isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let discovered = await discovery.currentBulbs()
        XCTAssertEqual(discovered.count, 1)

        // Round two: the bulb ignores the first two sends and answers only the third.
        bulb.setAnswersScan(false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        bulb.clearRecordedCommands()
        await discovery.scanNow()
        try await Task.sleep(nanoseconds: 500_000_000)
        bulb.setAnswersScan(true)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(scanCount(bulb), 3)

        // Stopping first means the closing round's own burst cannot answer and paper over
        // a miss, so the verdict below is only about round two.
        await discovery.stop()
        await discovery.scanNow()
        let bulbs = await discovery.currentBulbs()
        XCTAssertEqual(bulbs.count, 1)
        XCTAssertEqual(bulbs.first?.isReachable, true)
    }

    /// Settings lets the user change the rescan interval, so the stored value has to
    /// drive the running timer and stay inside the supported range.
    func testSetRescanIntervalStoresTheValueAndRestartsTheTimer() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 0.25,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        // The periodic timer scans on its own at the configured cadence.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThanOrEqual(scanCount(bulb), 3)

        // Moving to a long interval restarts the timer, so the fast scans stop.
        await discovery.setRescanInterval(20)
        let stored = await discovery.rescanInterval
        XCTAssertEqual(stored, 20)
        try await Task.sleep(nanoseconds: 300_000_000)
        bulb.clearRecordedCommands()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(scanCount(bulb), 0)

        // Out of range values clamp instead of producing a runaway or dead timer.
        await discovery.setRescanInterval(5)
        let clampedLow = await discovery.rescanInterval
        XCTAssertEqual(clampedLow, BulbDiscovery.minimumRescanInterval)

        await discovery.setRescanInterval(1_000)
        let clampedHigh = await discovery.rescanInterval
        XCTAssertEqual(clampedHigh, BulbDiscovery.maximumRescanInterval)
    }

    /// A reply whose `ip` is malformed must not become the bulb's endpoint: a malformed
    /// host converts to 255.255.255.255, so every later command would broadcast to every
    /// device on the network. Where the datagram actually came from is the truth.
    func testAnInvalidReplyIPFallsBackToTheDatagramSourceHost() async throws {
        let bulb = try FakeBulb(deviceID: "AA:00")
        defer { bulb.stop() }
        bulb.setReportedIP("not-an-ip")

        let socket = LANSocket(configuration: configuration(for: [bulb]))
        try socket.start()
        defer { socket.stop() }

        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration(for: [bulb]),
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3,
                                      scanRepeatSpacing: Self.fastBurstSpacing)
        await discovery.start()
        defer { Task { await discovery.stop() } }

        let found = try await waitForBulbs(discovery) { $0.count == 1 }
        XCTAssertEqual(found[0].endpoint.host, "127.0.0.1")
        XCTAssertEqual(found[0].endpoint, bulb.endpoint())
    }
}
