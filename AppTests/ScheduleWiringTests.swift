import XCTest
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

private func recordedBrightness(_ bulb: FakeBulb) -> [Int] {
    bulb.recordedCommands().compactMap { command in
        if case .brightness(let value) = command { return value }
        return nil
    }
}

private func recordedTemperatures(_ bulb: FakeBulb) -> [Int] {
    bulb.recordedCommands().compactMap { command in
        if case .colorTemperature(let kelvin) = command { return kelvin }
        return nil
    }
}

/// The part of Schedule that only `AppModel` can answer: which bulbs a timer runs on,
/// who is allowed to drive them, and what survives a relaunch.
@MainActor
final class ScheduleWiringTests: XCTestCase {

    private var sockets: [LANSocket] = []
    private var fakeBulbs: [FakeBulb] = []
    private var suiteName = ""
    private var loginItems = FakeLoginItemService()

    private struct Environment {
        var model: AppModel
        var ticker: ManualIntervalTicker
        var clock: ManualDateClock
        var nightShift: FakeNightShift
        var calendar: Calendar
    }

    override func tearDown() async throws {
        for socket in sockets { socket.stop() }
        sockets = []
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        loginItems = FakeLoginItemService()
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private func makeModel(bulbCount: Int, now: Date) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        return try makeEnvironment(now: now)
    }

    /// A second model over the same defaults suite and the same fake bulbs, which is what
    /// a relaunch looks like from the store's point of view.
    private func relaunch(now: Date) throws -> Environment {
        try makeEnvironment(now: now)
    }

    private func makeEnvironment(now: Date) throws -> Environment {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        let socket = LANSocket(configuration: configuration)
        sockets.append(socket)
        try socket.start()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration,
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3)
        let poller = StatusPoller(socket: socket, configuration: configuration, interval: 0.2)
        let ticker = ManualIntervalTicker()
        let clock = ManualDateClock(now)
        let nightShift = FakeNightShift()
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let model = AppModel(socket: socket,
                             discovery: discovery,
                             controller: controller,
                             poller: poller,
                             frameSource: ScriptedFrameSource(),
                             tickSource: ManualTickSource(),
                             sceneTickSource: ManualTickSource(),
                             scheduleTickSource: ticker,
                             scheduleClock: clock.reader,
                             calendar: calendar,
                             nightShift: nightShift,
                             settingsStore: SettingsStore(defaults: defaults),
                             nameStore: BulbNameStore(defaults: defaults),
                             loginItems: loginItems)
        return Environment(model: model,
                           ticker: ticker,
                           clock: clock,
                           nightShift: nightShift,
                           calendar: calendar)
    }

    private func date(_ calendar: Calendar,
                      day: Int = 16, hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                                         hour: hour, minute: minute, second: 0)))
    }

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func waitFor(timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: Settings

    func testTheLightModeAndTheScheduleSurviveARelaunch() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try date(calendar, hour: 12)
        let first = try makeModel(bulbCount: 0, now: noon)

        first.model.setLightMode(.auto)
        first.model.setShiftLength(minutes: 45)
        first.model.setScheduleEnabled(true)
        first.model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        first.model.setSleepTime(TimeOfDay(hour: 23, minute: 15))
        first.model.setWakeRamp(minutes: 20)
        first.model.setSleepRamp(minutes: 10)
        first.model.setWakeBrightness(70)

        let second = try relaunch(now: noon)
        XCTAssertEqual(second.model.lightMode, .auto)
        XCTAssertEqual(second.model.settings.shiftLengthMinutes, 45)
        XCTAssertTrue(second.model.scheduleSettings.isEnabled)
        XCTAssertEqual(second.model.scheduleSettings.wakeTime, TimeOfDay(hour: 6, minute: 30))
        XCTAssertEqual(second.model.scheduleSettings.sleepTime, TimeOfDay(hour: 23, minute: 15))
        XCTAssertEqual(second.model.scheduleSettings.wakeRampMinutes, 20)
        XCTAssertEqual(second.model.scheduleSettings.sleepRampMinutes, 10)
        XCTAssertEqual(second.model.scheduleSettings.wakeBrightness, 70)
    }

    func testPickingAModeRepublishesTheStatusTheCaptionReads() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let environment = try makeModel(bulbCount: 0, now: try date(calendar, hour: 12))
        XCTAssertEqual(environment.model.lightModeStatus.mode, .daylight)
        XCTAssertEqual(environment.model.lightModeStatus.origin, .fixed)

        environment.model.setLightMode(.night)
        XCTAssertEqual(environment.model.lightModeStatus.mode, .night)
        XCTAssertTrue(environment.model.lightModeStatus.isWarm)
        XCTAssertEqual(environment.model.lightModeKelvin, WhiteTemperature.nightKelvin)
    }

    func testTheNextEventLineIsEmptyUntilTheScheduleIsSwitchedOn() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let environment = try makeModel(bulbCount: 0, now: try date(calendar, hour: 12))
        XCTAssertNil(environment.model.nextScheduleEvent)

        environment.model.setScheduleEnabled(true)
        XCTAssertNotNil(environment.model.nextScheduleEvent)
    }

    // MARK: A real wake, through the whole object graph

    func testAWakeRunsOnTheDiscoveredBulbsInTheLightModesOwnWhite() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sixThirty = try date(calendar, hour: 6, minute: 30)
        let environment = try makeModel(bulbCount: 2, now: sixThirty.addingTimeInterval(-120))
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)

        environment.model.setLightMode(.night)
        await waitFor { !recordedTemperatures(self.fakeBulbs[0]).isEmpty }

        environment.model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        environment.model.setWakeRamp(minutes: 30)
        environment.model.setWakeBrightness(100)
        environment.model.setScheduleEnabled(true)

        environment.clock.set(sixThirty)
        environment.ticker.fire()

        guard case .waking = environment.model.scheduleState else {
            return XCTFail("Expected a wake ramp, got \(environment.model.scheduleState)")
        }
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(1) }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [1])
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700, 2700],
                       "The wake turns the bulbs on in the white the mode is holding.")
    }

    func testStartingPartyModeStopsARampWhereItStands() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sixThirty = try date(calendar, hour: 6, minute: 30)
        let environment = try makeModel(bulbCount: 2, now: sixThirty.addingTimeInterval(-120))
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)

        environment.model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        environment.model.setWakeRamp(minutes: 30)
        environment.model.setScheduleEnabled(true)
        environment.clock.set(sixThirty)
        environment.ticker.fire()
        guard case .waking = environment.model.scheduleState else {
            return XCTFail("Expected a wake ramp, got \(environment.model.scheduleState)")
        }

        environment.model.setPartyModeEnabled(true)
        XCTAssertEqual(environment.model.scheduleState, .idle)
        environment.model.setPartyModeEnabled(false)
    }

    func testTheAllRowPowerSwitchStopsARampAndOneBulbDoesNot() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sixThirty = try date(calendar, hour: 6, minute: 30)
        let environment = try makeModel(bulbCount: 2, now: sixThirty.addingTimeInterval(-120))
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)

        environment.model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        environment.model.setWakeRamp(minutes: 30)
        environment.model.setScheduleEnabled(true)
        environment.clock.set(sixThirty)
        environment.ticker.fire()

        // One row is one bulb, not the room, so the ramp carries on.
        let single = try XCTUnwrap(environment.model.bulbs.first)
        environment.model.setPower(false, for: single)
        guard case .waking = environment.model.scheduleState else {
            return XCTFail("One bulb must not stop a ramp")
        }

        environment.model.setPower(false, for: nil)
        XCTAssertEqual(environment.model.scheduleState, .idle)
    }

    func testAWakeIsSkippedWhileASceneIsRunning() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sixThirty = try date(calendar, hour: 6, minute: 30)
        let environment = try makeModel(bulbCount: 2, now: sixThirty.addingTimeInterval(-120))
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)

        environment.model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        environment.model.setWakeRamp(minutes: 30)
        environment.model.setScheduleEnabled(true)
        environment.model.setSceneEnabled(true)
        XCTAssertTrue(environment.model.isDrivingBulbs)

        environment.clock.set(sixThirty)
        environment.ticker.fire()

        XCTAssertEqual(environment.model.scheduleState, .idle)
        XCTAssertTrue(recordedBrightness(fakeBulbs[0]).isEmpty)
        environment.model.setSceneEnabled(false)
    }

    func testSleepStopsASceneBeforeItTakesTheBulbs() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let tenPM = try date(calendar, hour: 22)
        let environment = try makeModel(bulbCount: 2, now: tenPM.addingTimeInterval(-120))
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)

        environment.model.setSleepTime(TimeOfDay(hour: 22, minute: 0))
        environment.model.setSleepRamp(minutes: 0)
        environment.model.setScheduleEnabled(true)
        environment.model.setSceneEnabled(true)
        XCTAssertTrue(environment.model.isSceneRunning)

        environment.clock.set(tenPM)
        environment.ticker.fire()

        XCTAssertFalse(environment.model.isSceneRunning, "Sleep always wins.")
        XCTAssertEqual(environment.model.scheduleState, .idle)
    }
}
