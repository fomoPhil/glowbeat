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

private func recordedPower(_ bulb: FakeBulb) -> [Bool] {
    bulb.recordedCommands().compactMap { command in
        if case .turn(let on) = command { return on }
        return nil
    }
}

private func recordedTemperatures(_ bulb: FakeBulb) -> [Int] {
    bulb.recordedCommands().compactMap { command in
        if case .colorTemperature(let kelvin) = command { return kelvin }
        return nil
    }
}

/// The wake and sleep timers, proved against a clock the test moves by hand so an
/// overnight schedule costs milliseconds.
@MainActor
final class ScheduleEngineTests: XCTestCase {

    private var socket: LANSocket!
    private var fakeBulbs: [FakeBulb] = []
    private var suiteName = ""

    private struct Environment {
        var engine: ScheduleEngine
        var ticker: ManualIntervalTicker
        var clock: ManualDateClock
        var store: SettingsStore
        var bulbs: [Bulb]
        var calendar: Calendar
    }

    /// What the app would have done. Boxed because the engine's hooks are closures.
    @MainActor
    private final class Hooks {
        var isBusy = false
        var sleepStops = 0
        var kelvin = WhiteTemperature.daylightKelvin
    }

    private var hooks = Hooks()

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        hooks = Hooks()
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private func makeEnvironment(settings: ScheduleSettings,
                                 now: Date,
                                 bulbCount: Int = 2,
                                 reportedBrightness: Int? = nil) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        try socket.start()
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = SettingsStore(defaults: defaults)
        let ticker = ManualIntervalTicker()
        let clock = ManualDateClock(now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))

        let engine = ScheduleEngine(controller: controller,
                                    ticker: ticker,
                                    store: store,
                                    settings: settings,
                                    clock: clock.reader,
                                    calendar: calendar)
        let hooks = self.hooks
        engine.isBusy = { hooks.isBusy }
        engine.currentKelvin = { hooks.kelvin }
        engine.willRunSleep = { hooks.sleepStops += 1 }

        let bulbs = fakeBulbs.enumerated().map { index, fake in
            Bulb(id: "AA:0\(index)",
                 sku: "H6004",
                 endpoint: fake.endpoint(),
                 state: reportedBrightness.map {
                     BulbState(isOn: true, brightness: $0, color: GoveeRGB(r: 255, g: 255, b: 255),
                               colorTemperatureKelvin: 0)
                 })
        }
        engine.updateBulbs(bulbs)
        return Environment(engine: engine,
                           ticker: ticker,
                           clock: clock,
                           store: store,
                           bulbs: bulbs,
                           calendar: calendar)
    }

    private func date(_ calendar: Calendar,
                      day: Int = 16, hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                                         hour: hour, minute: minute, second: 0)))
    }

    private func settings(wakeRamp: Int = 0,
                          sleepRamp: Int = 0,
                          wakeBrightness: Int = 100,
                          isEnabled: Bool = true) -> ScheduleSettings {
        ScheduleSettings(isEnabled: isEnabled,
                         wakeTime: TimeOfDay(hour: 7, minute: 0),
                         sleepTime: TimeOfDay(hour: 22, minute: 0),
                         wakeRampMinutes: wakeRamp,
                         sleepRampMinutes: sleepRamp,
                         wakeBrightness: wakeBrightness)
    }

    private func waitFor(timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: Wake

    func testWakeOnTimeTurnsTheBulbsOnAtOnePercentAndRampsByWallClock() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(wakeRamp: 30), now: sevenAM)
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))
        hooks.kelvin = 5000

        environment.engine.reconcile(at: sevenAM)

        guard case .waking = environment.engine.state else {
            return XCTFail("Expected a wake ramp, got \(environment.engine.state)")
        }
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(1) }
        XCTAssertEqual(recordedPower(fakeBulbs[0]), [true])
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [5000])
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [1])

        environment.engine.reconcile(at: sevenAM.addingTimeInterval(15 * 60))
        await waitFor { recordedBrightness(self.fakeBulbs[0]).count >= 2 }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]).last, 51)

        environment.engine.reconcile(at: sevenAM.addingTimeInterval(30 * 60))
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(100) }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]).last, 100)
        XCTAssertEqual(environment.engine.state, .idle)
        // The mode applies again at the end of a wake ramp.
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [5000, 5000])
    }

    func testAWakeMissedWhileTheMacSleptCatchesUpWithoutARamp() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let lateMorning = try date(calendar, hour: 9, minute: 40)
        let environment = try makeEnvironment(settings: settings(wakeRamp: 30), now: lateMorning)
        // The lid was shut at eleven the night before.
        environment.store.saveLastReconciled(try date(calendar, day: 15, hour: 23))

        environment.engine.reconcile(at: lateMorning)

        XCTAssertEqual(environment.engine.state, .idle)
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(100) }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [100],
                       "A missed wake lands on its end state, not on a replayed sunrise.")
        XCTAssertEqual(recordedPower(fakeBulbs[0]), [true])
    }

    func testAWakeIsSkippedForTheDayWhilePartyModeIsRunning() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(wakeRamp: 30), now: sevenAM)
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))
        hooks.isBusy = true

        environment.engine.reconcile(at: sevenAM)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(environment.engine.state, .idle)
        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
        XCTAssertTrue(recordedBrightness(fakeBulbs[0]).isEmpty)

        // And it does not come back on the next tick: the window has moved past it.
        environment.engine.reconcile(at: sevenAM.addingTimeInterval(30))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
    }

    func testAWakeOlderThanTheCatchUpWindowIsLeftAlone() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let evening = try date(calendar, hour: 21)
        let environment = try makeEnvironment(settings: settings(), now: evening)
        // Glowbeat was shut for a week and is opened at nine at night. This morning's
        // wake time is technically unhandled, and lighting the room now would be nonsense.
        environment.store.saveLastReconciled(try date(calendar, day: 9, hour: 21))

        environment.engine.reconcile(at: evening)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(environment.engine.state, .idle)
        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
    }

    // MARK: Sleep

    func testSleepStopsPartyModeFirstAndThenDimsToOff() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let tenPM = try date(calendar, hour: 22)
        let environment = try makeEnvironment(settings: settings(sleepRamp: 20),
                                              now: tenPM,
                                              reportedBrightness: 80)
        environment.store.saveLastReconciled(tenPM.addingTimeInterval(-30))
        hooks.isBusy = true

        environment.engine.reconcile(at: tenPM)

        XCTAssertEqual(hooks.sleepStops, 1, "Sleep always wins; it stops the music first.")
        guard case .sleeping = environment.engine.state else {
            return XCTFail("Expected a sleep ramp, got \(environment.engine.state)")
        }
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(80) }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [80])

        environment.engine.reconcile(at: tenPM.addingTimeInterval(10 * 60))
        await waitFor { recordedBrightness(self.fakeBulbs[0]).count >= 2 }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]).last, 41)

        environment.engine.reconcile(at: tenPM.addingTimeInterval(20 * 60))
        await waitFor { recordedPower(self.fakeBulbs[0]).contains(false) }
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]).last, 1)
        XCTAssertEqual(recordedPower(fakeBulbs[0]), [false])
        XCTAssertEqual(environment.engine.state, .idle)
    }

    func testAMissedSleepJustPutsTheLightsOut() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let midnight = try date(calendar, day: 17, hour: 0, minute: 30)
        let environment = try makeEnvironment(settings: settings(sleepRamp: 20), now: midnight)
        environment.store.saveLastReconciled(try date(calendar, hour: 21))

        environment.engine.reconcile(at: midnight)

        XCTAssertEqual(environment.engine.state, .idle)
        await waitFor { recordedPower(self.fakeBulbs[0]).contains(false) }
        XCTAssertEqual(recordedPower(fakeBulbs[0]), [false])
        XCTAssertTrue(recordedBrightness(fakeBulbs[0]).isEmpty)
    }

    // MARK: Exclusion and the off switch

    func testAnythingElseTakingTheBulbsStopsARampWhereItStands() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(wakeRamp: 30), now: sevenAM)
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))

        environment.engine.reconcile(at: sevenAM)
        await waitFor { recordedBrightness(self.fakeBulbs[0]).contains(1) }

        environment.engine.cancelRamp()
        XCTAssertEqual(environment.engine.state, .idle)

        environment.engine.reconcile(at: sevenAM.addingTimeInterval(15 * 60))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [1],
                       "A stopped ramp does not pick itself back up on the next tick.")
    }

    func testASwitchedOffScheduleDoesNothingAtAll() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(isEnabled: false), now: sevenAM)
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))

        environment.engine.reconcile(at: sevenAM)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
        XCTAssertNil(environment.engine.nextEvent(at: sevenAM))
    }

    func testTurningTheScheduleOnDoesNotReplayTheDayItWasOffFor() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try date(calendar, hour: 12)
        let environment = try makeEnvironment(settings: settings(isEnabled: false), now: noon)
        environment.store.saveLastReconciled(try date(calendar, day: 15, hour: 12))

        environment.engine.setSettings(settings(isEnabled: true))
        environment.engine.reconcile(at: noon)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
    }

    func testAFirstEverLaunchHasNothingBehindItToCatchUpOn() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try date(calendar, hour: 12)
        let environment = try makeEnvironment(settings: settings(), now: noon)
        XCTAssertNil(environment.store.loadLastReconciled())

        environment.engine.reconcile(at: noon)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
        XCTAssertEqual(environment.store.loadLastReconciled(), noon)
    }

    // MARK: Bulbs that are not there yet

    func testATimerThatFiresWithNoBulbsOnTheNetworkLandsWhenTheyComeBack() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(wakeRamp: 30), now: sevenAM)
        environment.engine.updateBulbs([])
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))

        environment.engine.reconcile(at: sevenAM)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)

        // The smart switch restores power a couple of minutes later.
        environment.clock.set(sevenAM.addingTimeInterval(2 * 60))
        environment.engine.updateBulbs(environment.bulbs)

        await waitFor { recordedPower(self.fakeBulbs[0]).contains(true) }
        XCTAssertEqual(recordedPower(fakeBulbs[0]), [true])
        XCTAssertEqual(recordedBrightness(fakeBulbs[0]), [100],
                       "Two minutes late is too late for a ramp; the end state lands instead.")
    }

    func testAHeldEndStateIsDroppedOnceItIsTooOldToMeanAnything() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(), now: sevenAM)
        environment.engine.updateBulbs([])
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))

        environment.engine.reconcile(at: sevenAM)
        let muchLater = sevenAM.addingTimeInterval(ScheduleEngine.reachabilityGrace + 60)
        environment.clock.set(muchLater)
        environment.engine.reconcile(at: muchLater)
        environment.engine.updateBulbs(environment.bulbs)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(recordedPower(fakeBulbs[0]).isEmpty)
    }

    // MARK: The line the UI reads

    func testTheNextEventIsWhicheverTimerComesFirst() throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let environment = try makeEnvironment(settings: settings(),
                                              now: try date(calendar, hour: 12))

        let afternoon = try environment.engine.nextEvent(at: date(calendar, hour: 12))
        XCTAssertEqual(afternoon?.kind, .sleep)
        XCTAssertEqual(afternoon?.date, try date(calendar, hour: 22))

        let night = try environment.engine.nextEvent(at: date(calendar, hour: 23))
        XCTAssertEqual(night?.kind, .wake)
        XCTAssertEqual(night?.date, try date(calendar, day: 17, hour: 7))
    }

    // MARK: The poll itself

    func testStartingArmsTheThirtySecondPollAndStoppingDisarmsIt() throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let environment = try makeEnvironment(settings: settings(),
                                              now: try date(calendar, hour: 12))
        environment.engine.start()
        XCTAssertTrue(environment.ticker.isRunning)
        XCTAssertEqual(environment.ticker.interval, 30)
        environment.engine.stop()
        XCTAssertFalse(environment.ticker.isRunning)
    }

    func testATickAsksTheLightModeFirstSoAWakeUsesTheWhiteInForce() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let sevenAM = try date(calendar, hour: 7)
        let environment = try makeEnvironment(settings: settings(), now: sevenAM)
        environment.store.saveLastReconciled(sevenAM.addingTimeInterval(-30))
        let hooks = self.hooks
        environment.engine.onTick = { _ in hooks.kelvin = 2700 }
        environment.engine.start()
        environment.ticker.fire()

        await waitFor { !recordedTemperatures(self.fakeBulbs[0]).isEmpty }
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }
}

extension Calendar {
    /// One zone for the whole suite, so a schedule test asks the same question of the
    /// same clock wherever it is run.
    static func gregorianDenver() -> Calendar? {
        guard let zone = TimeZone(identifier: "America/Denver") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
