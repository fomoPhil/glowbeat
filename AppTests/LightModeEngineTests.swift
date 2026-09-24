import XCTest
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Every Kelvin a fake bulb was told to take.
private func recordedTemperatures(_ bulb: FakeBulb) -> [Int] {
    bulb.recordedCommands().compactMap { command in
        if case .colorTemperature(let kelvin) = command { return kelvin }
        return nil
    }
}

/// Daylight, Night and Auto. The real Night Shift client is never built here: it reads
/// private API and its answer depends on the time of day the suite happens to run at.
@MainActor
final class LightModeEngineTests: XCTestCase {

    private var socket: LANSocket!
    private var fakeBulbs: [FakeBulb] = []

    private struct Environment {
        var engine: LightModeEngine
        var nightShift: FakeNightShift
        var bulbs: [Bulb]
        var calendar: Calendar
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
    }

    private func makeEnvironment(mode: LightMode,
                                 shiftLengthMinutes: Int = 30) throws -> Environment {
        fakeBulbs = try (0..<2).map { try FakeBulb(deviceID: "AA:0\($0)") }
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let nightShift = FakeNightShift()
        let engine = LightModeEngine(controller: controller,
                                     source: nightShift,
                                     mode: mode,
                                     shiftLengthMinutes: shiftLengthMinutes,
                                     calendar: calendar)
        let bulbs = fakeBulbs.enumerated().map { index, fake in
            Bulb(id: "AA:0\(index)", sku: "H6004", endpoint: fake.endpoint())
        }
        engine.updateBulbs(bulbs)
        return Environment(engine: engine,
                           nightShift: nightShift,
                           bulbs: bulbs,
                           calendar: calendar)
    }

    private func date(_ calendar: Calendar,
                      day: Int = 16, hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day,
                                                         hour: hour, minute: minute, second: 0)))
    }

    private func sunSchedule(_ calendar: Calendar) throws -> SunSchedule {
        SunSchedule(previousSunrise: try date(calendar, day: 15, hour: 7, minute: 12),
                    sunrise: try date(calendar, day: 16, hour: 7, minute: 13),
                    nextSunrise: try date(calendar, day: 17, hour: 7, minute: 14),
                    previousSunset: try date(calendar, day: 15, hour: 19, minute: 33),
                    sunset: try date(calendar, day: 16, hour: 19, minute: 31),
                    nextSunset: try date(calendar, day: 17, hour: 19, minute: 29))
    }

    private func waitForTemperatures(_ count: Int, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordedTemperatures(fakeBulbs[0]).count >= count { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: The fixed modes

    func testPickingNightSendsTheWarmWhiteAtOnce() async throws {
        let environment = try makeEnvironment(mode: .daylight)
        environment.engine.setMode(.night, at: Date())
        await waitForTemperatures(1)

        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
        XCTAssertEqual(environment.engine.status.origin, .fixed)
        XCTAssertTrue(environment.engine.status.isWarm)
        // A mode change is a click, not a drift: it never runs the shift ramp.
        XCTAssertFalse(environment.engine.status.isShifting)
    }

    func testLaunchingAdoptsTheAnswerWithoutRepaintingTheRoom() async throws {
        let environment = try makeEnvironment(mode: .auto)
        environment.nightShift.status = .scripted(enabled: true, mode: .none)

        environment.engine.reconcile(at: Date())
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)
        XCTAssertTrue(recordedTemperatures(fakeBulbs[0]).isEmpty,
                      "Opening Glowbeat is not a request to change the room.")
    }

    // MARK: Auto following Night Shift

    func testAutoGoesWarmWhenNightShiftFlipsAndShiftsOverTheChosenLength() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 30)
        let calendar = environment.calendar
        let start = try date(calendar, hour: 22)
        // Switched on by hand, so there is no schedule to date the edge from and the
        // shift is measured from the moment Glowbeat noticed.
        // No sun schedule here on purpose: with one, "no schedule and not switched on"
        // would fall back to the sun and the room would already be warm at ten at night.
        environment.nightShift.status = .scripted(enabled: false, mode: .none)
        environment.engine.reconcile(at: start)
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.daylightKelvin)

        environment.nightShift.status = .scripted(enabled: true, mode: .none)
        environment.engine.reconcile(at: start)
        XCTAssertTrue(environment.engine.status.isWarm)
        XCTAssertTrue(environment.engine.status.isShifting)
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.daylightKelvin,
                       "The shift starts where the room already is.")

        environment.engine.reconcile(at: start.addingTimeInterval(15 * 60))
        XCTAssertEqual(environment.engine.kelvin, 4350, accuracy: 2)
        XCTAssertTrue(environment.engine.status.isShifting)

        environment.engine.reconcile(at: start.addingTimeInterval(30 * 60))
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)
        XCTAssertFalse(environment.engine.status.isShifting)

        await waitForTemperatures(2)
        let sent = recordedTemperatures(fakeBulbs[0])
        XCTAssertEqual(try XCTUnwrap(sent.first), 4350, accuracy: 2)
        XCTAssertEqual(sent.last, 2700)
    }

    /// A shift whose edge is already in the past is over before it begins, which is what
    /// a Mac that slept through sunset has to see when the lid opens.
    func testATransitionMissedWhileTheMacSleptLandsFinishedRatherThanRampingFromNow() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 30)
        let calendar = environment.calendar
        environment.nightShift.sunSchedule = try sunSchedule(calendar)
        environment.nightShift.status = .scripted(enabled: false, mode: .sunsetToSunrise)
        environment.engine.reconcile(at: try date(calendar, hour: 12))

        // Sunset was 19:31; the lid opens at 22:00 with Night Shift long since on.
        environment.nightShift.status = .scripted(enabled: true, mode: .sunsetToSunrise)
        environment.engine.reconcile(at: try date(calendar, hour: 22))

        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)
        XCTAssertFalse(environment.engine.status.isShifting)
        XCTAssertEqual(environment.engine.status.nextChange,
                       try date(calendar, day: 17, hour: 7, minute: 14))
        await waitForTemperatures(1)
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }

    // MARK: The solar fallback and the degraded cases

    func testAutoFollowsTheSunWhenNightShiftHasNoScheduleAndIsNotOn() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 0)
        let calendar = environment.calendar
        environment.nightShift.sunSchedule = try sunSchedule(calendar)
        environment.nightShift.status = .scripted(enabled: false, mode: .none)

        environment.engine.reconcile(at: try date(calendar, hour: 12))
        XCTAssertEqual(environment.engine.status.origin, .sun)
        XCTAssertFalse(environment.engine.status.isWarm)

        environment.engine.reconcile(at: try date(calendar, hour: 21))
        XCTAssertEqual(environment.engine.status.origin, .sun)
        XCTAssertTrue(environment.engine.status.isWarm)
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)
        XCTAssertEqual(environment.engine.status.nextChange,
                       try date(calendar, day: 17, hour: 7, minute: 14))
    }

    func testAutoFallsBackToTheSunWhenThePrivateApiDoesNotAnswer() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 0)
        let calendar = environment.calendar
        environment.nightShift.status = nil
        environment.nightShift.sunSchedule = try sunSchedule(calendar)

        environment.engine.reconcile(at: try date(calendar, hour: 12))
        environment.engine.reconcile(at: try date(calendar, hour: 21))

        XCTAssertEqual(environment.engine.status.origin, .sun)
        XCTAssertTrue(environment.engine.status.isWarm)
    }

    func testAutoRestsOnDaylightWhenNothingAnswersAtAll() async throws {
        let environment = try makeEnvironment(mode: .auto)
        environment.nightShift.status = nil
        environment.nightShift.sunSchedule = nil

        environment.engine.reconcile(at: Date())

        XCTAssertEqual(environment.engine.status.origin, .unavailable)
        XCTAssertFalse(environment.engine.status.isWarm)
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.daylightKelvin)
        XCTAssertNil(environment.engine.status.nextChange)
    }

    // MARK: Who owns the bulbs

    func testAShiftWorkedOutWhilePartyModeRunsIsAppliedOnceItStops() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 0)
        let calendar = environment.calendar
        environment.nightShift.status = .scripted(enabled: false, mode: .none)
        environment.nightShift.sunSchedule = try sunSchedule(calendar)
        environment.engine.reconcile(at: try date(calendar, hour: 12))

        environment.engine.setSuspended(true)
        environment.engine.reconcile(at: try date(calendar, hour: 21))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(recordedTemperatures(fakeBulbs[0]).isEmpty,
                      "Party Mode owns the bulbs; the light mode waits its turn.")
        XCTAssertEqual(environment.engine.kelvin, WhiteTemperature.nightKelvin)

        environment.engine.setSuspended(false)
        await waitForTemperatures(1)
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }

    /// Party Mode's last commands can still be on their way when it lets go. A white the
    /// light mode held back waits for whatever it is handed, so it lands after them rather
    /// than racing them on a second chain (the stop race, smoothness investigation H3).
    func testAWhiteHeldBackWaitsForWhatIsQueuedAheadOfIt() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 0)
        let calendar = environment.calendar
        environment.nightShift.status = .scripted(enabled: false, mode: .none)
        environment.nightShift.sunSchedule = try sunSchedule(calendar)
        environment.engine.reconcile(at: try date(calendar, hour: 12))
        environment.engine.setSuspended(true)
        environment.engine.reconcile(at: try date(calendar, hour: 21))
        XCTAssertTrue(environment.engine.hasPendingApply)

        let ahead = Task<Void, Never> { try? await Task.sleep(nanoseconds: 400_000_000) }
        environment.engine.setSuspended(false, after: ahead)
        XCTAssertFalse(environment.engine.hasPendingApply, "It is on its way, not pending.")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recordedTemperatures(fakeBulbs[0]).isEmpty,
                      "The white went out before what was queued ahead of it.")
        await waitForTemperatures(1)
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }

    /// Nothing missed, nothing pending: the room is left to whatever let go of it.
    func testNothingIsPendingWhenNoTransitionWasMissed() throws {
        let environment = try makeEnvironment(mode: .daylight)
        XCTAssertFalse(environment.engine.hasPendingApply)
        environment.engine.setSuspended(true)
        XCTAssertFalse(environment.engine.hasPendingApply)
        environment.engine.setMode(.night, at: Date())
        XCTAssertTrue(environment.engine.hasPendingApply, "A mode picked while suspended waits.")
        environment.engine.userPickedAColor()
        XCTAssertFalse(environment.engine.hasPendingApply, "A color picked by hand settles it.")
    }

    func testNothingIsAppliedTwiceWhenNoTransitionWasMissed() async throws {
        let environment = try makeEnvironment(mode: .daylight)
        environment.engine.setMode(.night, at: Date())
        await waitForTemperatures(1)

        environment.engine.setSuspended(true)
        environment.engine.setSuspended(false)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }

    func testATemperatureDecidedWithNoBulbsOnTheNetworkLandsWhenTheyAppear() async throws {
        let environment = try makeEnvironment(mode: .daylight)
        environment.engine.updateBulbs([])

        environment.engine.setMode(.night, at: Date())
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(recordedTemperatures(fakeBulbs[0]).isEmpty)

        environment.engine.updateBulbs(environment.bulbs)
        await waitForTemperatures(1)
        XCTAssertEqual(recordedTemperatures(fakeBulbs[0]), [2700])
    }

    func testTheNotificationBlockIsOnlyAHintToLookAgain() async throws {
        let environment = try makeEnvironment(mode: .auto, shiftLengthMinutes: 0)
        environment.engine.startObserving()
        XCTAssertTrue(environment.nightShift.isObserving)

        environment.nightShift.status = .scripted(enabled: false, mode: .none)
        environment.engine.reconcile(at: Date())
        let readsBefore = environment.nightShift.statusReads

        environment.nightShift.notifyChange()
        XCTAssertGreaterThan(environment.nightShift.statusReads, readsBefore)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(recordedTemperatures(fakeBulbs[0]).isEmpty,
                      "Nothing moved, so nothing is sent.")
    }
}
