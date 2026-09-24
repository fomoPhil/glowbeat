import XCTest
import GoveeLANTestSupport
@testable import GoveeLAN

final class BulbControllerTests: XCTestCase {

    private func makeSocket(for bulbs: [FakeBulb]) throws -> LANSocket {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: bulbs.map { $0.endpoint() })
        let socket = LANSocket(configuration: configuration)
        try socket.start()
        return socket
    }

    private func bulb(for fake: FakeBulb, id: String) -> Bulb {
        Bulb(id: id, sku: "H6004", endpoint: fake.endpoint())
    }

    /// A controller built without a rate streams at the package's own default rather
    /// than at a number copied into the configuration.
    func testTheDefaultConfigurationStreamsAtTheDefaultRate() {
        XCTAssertEqual(BulbController.Configuration().maxStreamedSendsPerSecond,
                       StreamRateLimiter.defaultSendsPerSecond)
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool,
                           timeout: TimeInterval = 3,
                           message: String) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail(message)
    }

    private func colorValues(from fake: FakeBulb) -> [GoveeRGB] {
        fake.recordedCommands().compactMap { command in
            if case .color(let rgb) = command { return rgb }
            return nil
        }
    }

    private func brightnessValues(from fake: FakeBulb) -> [Int] {
        fake.recordedCommands().compactMap { command in
            if case .brightness(let value) = command { return value }
            return nil
        }
    }

    func testOneShotCommandsAreSentThreeTimes() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 0.02,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        await controller.turn(true, bulbs: [bulb(for: fake, id: "AA:00")])

        await waitUntil({
            fake.recordedCommands().filter { $0 == .turn(true) }.count == 3
        }, message: "Expected exactly three turn commands.")
        XCTAssertTrue(fake.currentState().isOn)
    }

    func testANewOneShotCancelsTheStaleRepeatsOfThePreviousOne() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 0.3,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setBrightness(30, bulbs: [target])
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.setBrightness(70, bulbs: [target])

        // Long enough for both repeat schedules to have run to completion.
        try await Task.sleep(nanoseconds: 900_000_000)

        let values = brightnessValues(from: fake)
        XCTAssertEqual(values.filter { $0 == 30 }.count, 1,
                       "The superseded brightness must go out once and never be retried.")
        XCTAssertEqual(values.filter { $0 == 70 }.count, 3,
                       "The newest brightness keeps its own three sends.")
        guard let firstSeventy = values.firstIndex(of: 70) else {
            return XCTFail("The newest brightness never reached the bulb: \(values)")
        }
        XCTAssertFalse(values[firstSeventy...].contains(30),
                       "A stale brightness reached the bulb after the new one: \(values)")

        let lastBrightness = await controller.lastSentBrightness(for: "AA:00")
        XCTAssertEqual(lastBrightness, 70)
        XCTAssertEqual(fake.currentState().brightness, 70)
    }

    /// Color and white temperature are the same `colorwc` command and the bulb can only
    /// be in one of the two modes, so a Kelvin has to cancel a color's pending retries
    /// and the other way round. Without that, picking a color and then a white
    /// temperature inside the repeat window leaves the stale color landing last, and the
    /// bulb visibly jumps back out of white mode a second later. Identify hits the same
    /// window: it flashes white and then restores a bulb that was in white mode.
    func testAWhiteTemperatureCancelsThePendingRepeatsOfAColor() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 0.3,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setColor(GoveeRGB(r: 255, g: 0, b: 0), bulbs: [target])
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.setColorTemperature(kelvin: 3200, bulbs: [target])

        // Past every repeat either command could have scheduled.
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertEqual(colorValues(from: fake).filter { $0 == GoveeRGB(r: 255, g: 0, b: 0) }.count, 1,
                       "The superseded color must go out once and never be retried.")
        XCTAssertEqual(fake.currentState().colorTemperatureKelvin, 3200,
                       "A stale color retry dropped the bulb back out of white mode.")
    }

    func testAColorCancelsThePendingRepeatsOfAWhiteTemperature() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 0.3,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setColorTemperature(kelvin: 3200, bulbs: [target])
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.setColor(GoveeRGB(r: 0, g: 255, b: 0), bulbs: [target])

        try await Task.sleep(nanoseconds: 1_100_000_000)

        let kelvins = fake.recordedCommands().compactMap { command -> Int? in
            if case .colorTemperature(let value) = command { return value }
            return nil
        }
        XCTAssertEqual(kelvins.count, 1,
                       "The superseded white temperature must go out once and never be retried.")
        XCTAssertEqual(fake.currentState().colorTemperatureKelvin, 0)
        XCTAssertEqual(fake.currentState().color, GoveeRGB(r: 0, g: 255, b: 0))
    }

    func testBrightnessAndColorReachTheBulbAndAreRecordedAsSent() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 2,
                                                             repeatInterval: 0.02,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setBrightness(55, bulbs: [target])
        await controller.setColor(GoveeRGB(r: 10, g: 20, b: 30), bulbs: [target])

        await waitUntil({
            fake.currentState().brightness == 55
                && fake.currentState().color == GoveeRGB(r: 10, g: 20, b: 30)
        }, message: "Bulb did not reach the commanded brightness and color.")

        let lastBrightness = await controller.lastSentBrightness(for: "AA:00")
        let lastPower = await controller.lastSentPower(for: "AA:00")
        let recent = await controller.recentSentColors(for: "AA:00")
        XCTAssertEqual(lastBrightness, 55)
        XCTAssertNil(lastPower)
        XCTAssertEqual(recent.last, GoveeRGB(r: 10, g: 20, b: 30))
    }

    func testColorTemperatureRecordsTheBlackItPutsOnTheWire() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setColorTemperature(kelvin: 4000, bulbs: [target])

        await waitUntil({
            fake.currentState().colorTemperatureKelvin == 4000
        }, message: "The bulb never received the color temperature command.")

        // colorwc(kelvin:) puts r, g, b = 0 on the wire and the bulb reports that back,
        // so the send history has to own the black or takeover detection sees a phantom.
        let recent = await controller.recentSentColors(for: "AA:00")
        XCTAssertEqual(recent.last, GoveeRGB(r: 0, g: 0, b: 0))
    }

    func testRecentSentColorsKeepsAtMostFiveEntriesNewestLast() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        // Spaced past the 100 ms gap so every submission is sent, not coalesced.
        for value in 1...8 {
            await controller.streamColor(GoveeRGB(r: UInt8(value), g: 0, b: 0), to: target)
            try await Task.sleep(nanoseconds: 110_000_000)
        }

        let recent = await controller.recentSentColors(for: "AA:00")
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.last, GoveeRGB(r: 8, g: 0, b: 0))
    }

    /// Phone takeover detection reads this. With a history of five colors, a second and a
    /// half of Party Mode left only the last half second, and a bulb reporting anything
    /// older was read as the Govee phone app (Phil, 2026-09-23).
    func testEveryColorStreamedInTheTakeoverWindowIsKeptWithItsSendTime() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        XCTAssertEqual(BulbController.Configuration().takeoverHistoryWindow, 3)
        let target = bulb(for: fake, id: "AA:00")
        let colors = (1...15).map { (step: Int) -> GoveeRGB in
            GoveeRGB(r: UInt8(step * 10), g: 0, b: 0)
        }
        // Stamped a tick apart, the way the engine hands them over, so none is coalesced.
        let tick = Date()
        for (index, color) in colors.enumerated() {
            await controller.streamColor(color, to: target, at: tick.addingTimeInterval(Double(index) * 0.1))
        }
        let asked = Date()

        let history = await controller.sentColorHistory(for: "AA:00", asOf: asked)
        XCTAssertEqual(history.map(\.color), colors)
        XCTAssertTrue(history.allSatisfy { $0.sentAt >= tick && $0.sentAt <= asked },
                      "Each color is stamped when it went out.")
        // The count bounded view is unchanged: the last five.
        let recent = await controller.recentSentColors(for: "AA:00")
        XCTAssertEqual(recent, Array(colors.suffix(5)))
    }

    func testClearingTheSendHistoryEmptiesTheTakeoverWindowToo() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.streamColor(GoveeRGB(r: 1, g: 2, b: 3), to: target)
        await controller.setColor(GoveeRGB(r: 4, g: 5, b: 6), bulbs: [target])
        let seeded = await controller.sentColorHistory(for: "AA:00", asOf: Date())
        XCTAssertEqual(seeded.map(\.color), [GoveeRGB(r: 1, g: 2, b: 3), GoveeRGB(r: 4, g: 5, b: 6)])

        await controller.clearSendHistory()
        let cleared = await controller.sentColorHistory(for: "AA:00", asOf: Date())
        XCTAssertEqual(cleared, [])
    }

    func testStreamedColorsAreCoalescedAndTheLatestHeldColorIsFlushed() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        for value in 1...20 {
            await controller.streamColor(GoveeRGB(r: UInt8(value), g: 0, b: 0), to: target)
        }
        // The burst spans about a millisecond, so nineteen colors are held back. Wait
        // past the 125 ms gap, then flush the way the engine tick does.
        try await Task.sleep(nanoseconds: 200_000_000)
        await controller.flushStreamed(bulbs: [target])

        await waitUntil({
            fake.currentState().color == GoveeRGB(r: 20, g: 0, b: 0)
        }, message: "The latest held color never reached the bulb, so latest value did not win.")

        let colorCommands = fake.recordedCommands().filter {
            if case .color = $0 { return true }
            return false
        }
        // One immediate send plus one flushed send. Twenty submissions must never
        // become twenty datagrams.
        XCTAssertGreaterThanOrEqual(colorCommands.count, 2)
        XCTAssertLessThanOrEqual(colorCommands.count, 4)

        let recent = await controller.recentSentColors(for: "AA:00")
        XCTAssertEqual(recent.last, GoveeRGB(r: 20, g: 0, b: 0))
    }

    /// The engine stamps one time per tick and hands it to the actor, so two ticks a
    /// full gap apart both send even though the actor runs them back to back.
    func testAStreamedColorUsesTheTimeTheCallerStampedNotTheActorsOwnClock() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        let tick = Date()
        await controller.streamColor(GoveeRGB(r: 1, g: 0, b: 0), to: target, at: tick)
        await controller.streamColor(GoveeRGB(r: 2, g: 0, b: 0),
                                     to: target,
                                     at: tick.addingTimeInterval(0.125))

        await waitUntil({
            let colors = fake.recordedCommands().compactMap { command -> GoveeRGB? in
                if case .color(let rgb) = command { return rgb }
                return nil
            }
            return colors.contains(GoveeRGB(r: 1, g: 0, b: 0))
                && colors.contains(GoveeRGB(r: 2, g: 0, b: 0))
        }, message: "The second tick was held back, so the stamped time was ignored.")
    }

    /// Party Mode off then on inside two seconds used to let the settle color's repeats
    /// land at plus one and plus two seconds, on top of the live stream, so the room
    /// flashed back to the dim base twice after Party Mode had already restarted.
    func testAStreamedColorCancelsThePendingRepeatsOfAOneShotColor() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 1.0,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        let settle = GoveeRGB(r: 10, g: 20, b: 30)
        let streamed = GoveeRGB(r: 200, g: 50, b: 50)

        await controller.setColor(settle, bulbs: [target])
        try await Task.sleep(nanoseconds: 100_000_000)
        await controller.streamColor(streamed, to: target)

        // Past both scheduled repeats of the one shot.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let colors = colorValues(from: fake)
        XCTAssertEqual(colors.filter { $0 == settle }.count, 1,
                       "The one shot color was repeated over the live stream: \(colors)")
        guard let firstStreamed = colors.firstIndex(of: streamed) else {
            return XCTFail("The streamed color never reached the bulb: \(colors)")
        }
        XCTAssertFalse(colors[firstStreamed...].contains(settle),
                       "A stale one shot color landed after the stream started: \(colors)")
    }

    /// The same guarantee for the other half of the fix: clearing the send history is
    /// what a new Party Mode session does first, so nothing scheduled by the old session
    /// may survive it.
    func testClearingTheSendHistoryCancelsPendingRepeats() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 3,
                                                             repeatInterval: 0.4,
                                                             maxStreamedSendsPerSecond: 8,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        await controller.setBrightness(42, bulbs: [target])
        await controller.clearSendHistory()
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(brightnessValues(from: fake).filter { $0 == 42 }.count, 1,
                       "Clearing the send history must cancel every pending repeat.")
    }

    // MARK: The room's send budget

    /// The controller reports the rate it is streaming at, which is the one the engine
    /// last worked out for the room, not the one it was built with.
    func testTheStreamRateCanBeReadBack() async throws {
        let socket = LANSocket(configuration: LANConfiguration(replyPort: 0,
                                                               commandPort: .matchingReplySource,
                                                               joinsMulticast: false))
        let controller = BulbController(socket: socket,
                                        configuration: .init(maxStreamedSendsPerSecond: 10))
        let initial = await controller.maxStreamedSendsPerSecond
        XCTAssertEqual(initial, 10)
        await controller.setMaxStreamedSendsPerSecond(6)
        let lowered = await controller.maxStreamedSendsPerSecond
        XCTAssertEqual(lowered, 6)
    }

    /// Ten seconds of Party Mode in a room of `count` bulbs, on a scripted clock: every
    /// tick a new color for every bulb, stamped the way the engine stamps a tick, at the
    /// per bulb rate the room budget gives. Returns how many colors went on the wire in
    /// each scripted second, after checking the fake bulbs received every one of them.
    private func scriptedRoomRun(bulbCount count: Int) async throws -> (rate: Int, perSecond: [Int]) {
        let fakes = try (0..<count).map { try FakeBulb(deviceID: "BB:\($0)") }
        defer { fakes.forEach { $0.stop() } }
        let socket = try makeSocket(for: fakes)
        defer { socket.stop() }
        let rate = StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: count)
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0,
                                                             maxStreamedSendsPerSecond: 10))
        await controller.setMaxStreamedSendsPerSecond(rate)
        let room = fakes.enumerated().map { bulb(for: $1, id: "BB:\($0)") }

        let start = Date(timeIntervalSince1970: 2_000_000)
        var perSecond = [Int](repeating: 0, count: 10)
        for tick in 0..<(10 * rate) {
            let now = start.addingTimeInterval(Double(tick) / Double(rate))
            let second = tick / rate
            for (index, target) in room.enumerated() {
                let color = GoveeRGB(r: UInt8(tick % 256), g: UInt8(index), b: 7)
                if await controller.streamColor(color, to: target, at: now) {
                    perSecond[second] += 1
                }
            }
            perSecond[second] += await controller.flushStreamed(bulbs: room, at: now).count
        }

        let sent = perSecond.reduce(0, +)
        await waitUntil({
            fakes.map { fake in
                fake.recordedCommands().filter { if case .color = $0 { return true }; return false }.count
            }.reduce(0, +) == sent
        }, timeout: 5, message: "The fake bulbs did not receive every color the controller sent.")
        return (rate, perSecond)
    }

    func testATenSecondRunWithTenBulbsNeverExceedsTheRoomBudget() async throws {
        let run = try await scriptedRoomRun(bulbCount: 10)
        XCTAssertEqual(run.rate, 6)
        for (second, count) in run.perSecond.enumerated() {
            XCTAssertLessThanOrEqual(count, StreamRateLimiter.roomBudgetPerSecond,
                                     "Second \(second) sent \(count) colors to the room.")
        }
        // And nothing was starved to get there: every bulb got every tick.
        XCTAssertEqual(run.perSecond.reduce(0, +), 10 * 6 * 10)
    }

    func testATenSecondRunWithFifteenBulbsNeverExceedsTheRoomBudget() async throws {
        let run = try await scriptedRoomRun(bulbCount: 15)
        XCTAssertEqual(run.rate, 4)
        for (second, count) in run.perSecond.enumerated() {
            XCTAssertLessThanOrEqual(count, StreamRateLimiter.roomBudgetPerSecond,
                                     "Second \(second) sent \(count) colors to the room.")
        }
        XCTAssertEqual(run.perSecond.reduce(0, +), 15 * 4 * 10)
    }

    // MARK: What the opt-in Party Mode trace reads

    /// `streamColor` says whether a color went out or was held, and `flushStreamed` names
    /// the bulbs a held color was released to. Nothing else changes: these are the same
    /// sends the rate limiter always made.
    func testStreamingReportsSentHeldAndReleased() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        let start = Date()
        let red = GoveeRGB(r: 255, g: 0, b: 0)
        let blue = GoveeRGB(r: 0, g: 0, b: 255)

        let first = await controller.streamColor(red, to: target, at: start)
        let second = await controller.streamColor(blue, to: target, at: start.addingTimeInterval(0.01))
        let tooSoon = await controller.flushStreamed(bulbs: [target], at: start.addingTimeInterval(0.02))
        let later = await controller.flushStreamed(bulbs: [target], at: start.addingTimeInterval(0.2))

        XCTAssertTrue(first, "The first color has nothing to wait for.")
        XCTAssertFalse(second, "Ten milliseconds later the limiter holds it.")
        XCTAssertEqual(tooSoon, [], "Still inside the gap, so nothing is released.")
        XCTAssertEqual(later, ["AA:00"], "Once the gap has passed the held color goes out.")
        await waitUntil({
            fake.recordedCommands().compactMap { command -> GoveeRGB? in
                if case .color(let rgb) = command { return rgb }
                return nil
            } == [red, blue]
        }, message: "The bulb should hear red, then the released blue.")
    }

    /// The trace's view of everything that is not the stream: every one shot command and
    /// every repeat, and an observer that only its own token can remove.
    func testACommandObserverSeesOneShotsAndRepeatsAndOnlyItsTokenRemovesIt() async throws {
        let fake = try FakeBulb(deviceID: "AA:00")
        defer { fake.stop() }
        let socket = try makeSocket(for: [fake])
        defer { socket.stop() }
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 2,
                                                             repeatInterval: 0.02,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let target = bulb(for: fake, id: "AA:00")
        let seen = EventBox()
        let hasNone = await controller.hasCommandObserver
        XCTAssertFalse(hasNone)

        let token = await controller.addCommandObserver { seen.append($0) }
        await controller.setColorTemperature(kelvin: 2700, bulbs: [target])
        await controller.setBrightness(40, bulbs: [target])
        await waitUntil({ seen.values.count == 4 }, message: "Two commands and one repeat of each.")
        XCTAssertEqual(Set(seen.values), [.colorTemperature(kelvin: 2700, bulbIDs: ["AA:00"]),
                                          .brightness(40, bulbIDs: ["AA:00"]),
                                          .repeated(.color, bulbID: "AA:00"),
                                          .repeated(.brightness, bulbID: "AA:00")])

        // Streamed colors are the engine's to report, not the observer's.
        await controller.streamColor(GoveeRGB(r: 1, g: 2, b: 3), to: target)
        XCTAssertEqual(seen.values.count, 4)

        let replacement = await controller.addCommandObserver { _ in }
        await controller.removeCommandObserver(token)
        let stillObserved = await controller.hasCommandObserver
        XCTAssertTrue(stillObserved, "A stale token must not remove the newer observer.")
        await controller.removeCommandObserver(replacement)
        let cleared = await controller.hasCommandObserver
        XCTAssertFalse(cleared)
    }
}

/// Collects observer events from any thread.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BulbCommandEvent] = []

    func append(_ event: BulbCommandEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var values: [BulbCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
