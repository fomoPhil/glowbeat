import XCTest
@testable import Glowbeat

/// The value types the Schedule feature is built out of: the Kelvin clamp, the wall clock
/// ramp, the time of day lookups, and what survives a relaunch.
@MainActor
final class ScheduleModelTests: XCTestCase {

    private var suiteName = ""

    override func tearDown() async throws {
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private func makeStore() throws -> (SettingsStore, UserDefaults) {
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (SettingsStore(defaults: defaults), defaults)
    }

    /// A calendar pinned to one zone, so a suite run in any time zone asks the same
    /// question of the same clock.
    private func fixedCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        return calendar
    }

    private func date(_ calendar: Calendar,
                      year: Int = 2026, month: Int = 9, day: Int = 16,
                      hour: Int, minute: Int = 0) throws -> Date {
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: 0)
        return try XCTUnwrap(calendar.date(from: components))
    }

    // MARK: The Kelvin clamp

    func testKelvinIsClampedToWhatAnH6004Accepts() {
        XCTAssertEqual(WhiteTemperature.clamped(1000), 2700)
        XCTAssertEqual(WhiteTemperature.clamped(2000), 2700)
        XCTAssertEqual(WhiteTemperature.clamped(2700), 2700)
        XCTAssertEqual(WhiteTemperature.clamped(4000), 4000)
        XCTAssertEqual(WhiteTemperature.clamped(6500), 6500)
        // The protocol advertises 9000, the bulb ignores anything past 6500 in silence.
        XCTAssertEqual(WhiteTemperature.clamped(9000), 6500)
    }

    func testTheDoubleKelvinClampRoundsAndSurvivesNonsense() {
        XCTAssertEqual(WhiteTemperature.clamped(4000.4), 4000)
        XCTAssertEqual(WhiteTemperature.clamped(4000.6), 4001)
        XCTAssertEqual(WhiteTemperature.clamped(Double.nan), WhiteTemperature.daylightKelvin)
        XCTAssertEqual(WhiteTemperature.clamped(Double.infinity), WhiteTemperature.maximumKelvin)
        XCTAssertEqual(WhiteTemperature.clamped(-Double.infinity), WhiteTemperature.minimumKelvin)
        XCTAssertEqual(WhiteTemperature.clamped(1e300), WhiteTemperature.maximumKelvin)
    }

    func testTheTwoModeTemperaturesAreInsideTheClamp() {
        XCTAssertEqual(LightMode.night.fixedKelvin, 2700)
        XCTAssertEqual(LightMode.daylight.fixedKelvin, 6000)
        XCTAssertNil(LightMode.auto.fixedKelvin)
        XCTAssertEqual(WhiteTemperature.clamped(WhiteTemperature.daylightKelvin), 6000)
        XCTAssertEqual(WhiteTemperature.clamped(WhiteTemperature.nightKelvin), 2700)
    }

    // MARK: The ramp

    func testAThirtyMinuteRampInterpolatesByWallClock() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ramp = LightRamp(start: start, duration: 30 * 60, from: 1, to: 100)

        XCTAssertEqual(ramp.value(at: start), 1, accuracy: 0.001)
        XCTAssertEqual(ramp.value(at: start.addingTimeInterval(15 * 60)), 50.5, accuracy: 0.001)
        XCTAssertEqual(ramp.value(at: start.addingTimeInterval(30 * 60)), 100, accuracy: 0.001)
        XCTAssertFalse(ramp.isFinished(at: start.addingTimeInterval(29 * 60)))
        XCTAssertTrue(ramp.isFinished(at: start.addingTimeInterval(30 * 60)))
    }

    /// The whole reason a ramp holds a `Date`: the Mac can be asleep for most of it and
    /// the room still has to land where the clock says it should.
    func testARampReadLongAfterItEndedIsSimplyOver() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ramp = LightRamp(start: start, duration: 30 * 60, from: 6000, to: 2700)
        let hoursLater = start.addingTimeInterval(9 * 60 * 60)

        XCTAssertEqual(ramp.value(at: hoursLater), 2700, accuracy: 0.001)
        XCTAssertTrue(ramp.isFinished(at: hoursLater))
        // And before it began it is still at its start, not extrapolated backwards.
        XCTAssertEqual(ramp.value(at: start.addingTimeInterval(-60)), 6000, accuracy: 0.001)
    }

    func testARampWithNoDurationIsOverAsSoonAsItStarts() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let ramp = LightRamp(start: start, duration: 0, from: 1, to: 100)
        XCTAssertEqual(ramp.value(at: start), 100, accuracy: 0.001)
        XCTAssertTrue(ramp.isFinished(at: start))

        // A negative duration is the same thing rather than a trap.
        let backwards = LightRamp(start: start, duration: -60, from: 1, to: 100)
        XCTAssertEqual(backwards.duration, 0)
        XCTAssertTrue(backwards.isFinished(at: start))
    }

    // MARK: Time of day

    func testTheMostRecentOccurrenceIncludesTheMomentItself() throws {
        let calendar = try fixedCalendar()
        let sevenAM = try date(calendar, hour: 7)
        let time = TimeOfDay(hour: 7, minute: 0)

        XCTAssertEqual(time.mostRecentOccurrence(onOrBefore: sevenAM, calendar: calendar), sevenAM)
        let justBefore = sevenAM.addingTimeInterval(-1)
        let yesterday = try date(calendar, day: 15, hour: 7)
        XCTAssertEqual(time.mostRecentOccurrence(onOrBefore: justBefore, calendar: calendar),
                       yesterday)
    }

    func testTheNextOccurrenceIsStrictlyLater() throws {
        let calendar = try fixedCalendar()
        let sevenAM = try date(calendar, hour: 7)
        let time = TimeOfDay(hour: 7, minute: 0)
        let tomorrow = try date(calendar, day: 17, hour: 7)

        XCTAssertEqual(time.nextOccurrence(after: sevenAM, calendar: calendar), tomorrow)
        XCTAssertEqual(time.nextOccurrence(after: try date(calendar, hour: 6), calendar: calendar),
                       sevenAM)
    }

    func testTimeOfDayIsClampedAndOrdered() {
        XCTAssertEqual(TimeOfDay(hour: 99, minute: 99), TimeOfDay(hour: 23, minute: 59))
        XCTAssertEqual(TimeOfDay(hour: -4, minute: -1), TimeOfDay(hour: 0, minute: 0))
        XCTAssertTrue(TimeOfDay(hour: 6, minute: 30) < TimeOfDay(hour: 7, minute: 0))
        XCTAssertEqual(TimeOfDay(hour: 6, minute: 30).minutesFromMidnight, 390)
    }

    // MARK: Settings clamps

    func testScheduleSettingsClampEverythingOnTheWayIn() {
        let settings = ScheduleSettings(isEnabled: true,
                                        wakeTime: TimeOfDay(hour: 6, minute: 30),
                                        sleepTime: TimeOfDay(hour: 22, minute: 15),
                                        wakeRampMinutes: 999,
                                        sleepRampMinutes: -10,
                                        wakeBrightness: 0)
        XCTAssertEqual(settings.wakeRampMinutes, 60)
        XCTAssertEqual(settings.sleepRampMinutes, 0)
        // Zero brightness is what a bulb reports when it is off, so a wake never lands there.
        XCTAssertEqual(settings.wakeBrightness, 1)
        XCTAssertEqual(settings.wakeRamp, 3600, accuracy: 0.001)
    }

    func testTheShippedScheduleIsOffAndTheShippedModeIsDaylight() {
        XCTAssertFalse(GlowbeatSettings.defaults.schedule.isEnabled)
        XCTAssertEqual(GlowbeatSettings.defaults.lightMode, .daylight)
        XCTAssertEqual(GlowbeatSettings.defaults.shiftLengthMinutes, 30)
        XCTAssertEqual(GlowbeatSettings.clampedShiftLengthMinutes(999), 120)
        XCTAssertEqual(GlowbeatSettings.clampedShiftLengthMinutes(-5), 0)
    }

    // MARK: Persistence

    func testTheLightModeAndTheScheduleRoundTrip() throws {
        let (store, _) = try makeStore()
        var settings = GlowbeatSettings.defaults
        settings.lightMode = .auto
        settings.shiftLengthMinutes = 45
        settings.schedule = ScheduleSettings(isEnabled: true,
                                             wakeTime: TimeOfDay(hour: 6, minute: 30),
                                             sleepTime: TimeOfDay(hour: 23, minute: 15),
                                             wakeRampMinutes: 20,
                                             sleepRampMinutes: 10,
                                             wakeBrightness: 80)
        store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.lightMode, .auto)
        XCTAssertEqual(loaded.shiftLengthMinutes, 45)
        XCTAssertEqual(loaded.schedule, settings.schedule)
    }

    func testAnEmptyStoreReadsTheShippedScheduleAndMode() throws {
        let (store, _) = try makeStore()
        let loaded = store.load()
        XCTAssertEqual(loaded.lightMode, GlowbeatSettings.defaults.lightMode)
        XCTAssertEqual(loaded.shiftLengthMinutes, GlowbeatSettings.defaults.shiftLengthMinutes)
        XCTAssertEqual(loaded.schedule, GlowbeatSettings.defaults.schedule)
        XCTAssertNil(store.loadLastReconciled())
    }

    func testAHandEditedStoreCannotPutTheScheduleIntoABadState() throws {
        let (store, defaults) = try makeStore()
        defaults.set("moonlight", forKey: "lightModeID")
        defaults.set(9999, forKey: "shiftLengthMinutes")
        defaults.set(true, forKey: "scheduleEnabled")
        defaults.set(31, forKey: "scheduleWakeHour")
        defaults.set(-4, forKey: "scheduleWakeMinute")
        defaults.set(500, forKey: "scheduleWakeRampMinutes")
        defaults.set(0, forKey: "scheduleWakeBrightness")

        let loaded = store.load()
        XCTAssertEqual(loaded.lightMode, .daylight)
        XCTAssertEqual(loaded.shiftLengthMinutes, 120)
        XCTAssertEqual(loaded.schedule.wakeTime, TimeOfDay(hour: 23, minute: 0))
        XCTAssertEqual(loaded.schedule.wakeRampMinutes, 60)
        XCTAssertEqual(loaded.schedule.wakeBrightness, 1)
    }

    func testTheLastReconciledMomentRoundTripsAndClears() throws {
        let (store, _) = try makeStore()
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        store.saveLastReconciled(moment)
        XCTAssertEqual(store.loadLastReconciled(), moment)
        store.clearLastReconciled()
        XCTAssertNil(store.loadLastReconciled())
    }

    // MARK: The sun

    func testTheSunScheduleFindsThePairEitherSideOfNow() throws {
        let calendar = try fixedCalendar()
        let schedule = SunSchedule(previousSunrise: try date(calendar, day: 15, hour: 7, minute: 12),
                                   sunrise: try date(calendar, day: 16, hour: 7, minute: 13),
                                   nextSunrise: try date(calendar, day: 17, hour: 7, minute: 14),
                                   previousSunset: try date(calendar, day: 15, hour: 19, minute: 33),
                                   sunset: try date(calendar, day: 16, hour: 19, minute: 31),
                                   nextSunset: try date(calendar, day: 17, hour: 19, minute: 29))

        let noon = try date(calendar, day: 16, hour: 12)
        let day = try XCTUnwrap(schedule.phase(at: noon))
        XCTAssertFalse(day.isNight)
        XCTAssertEqual(day.since, try date(calendar, day: 16, hour: 7, minute: 13))
        XCTAssertEqual(day.until, try date(calendar, day: 16, hour: 19, minute: 31))

        let evening = try date(calendar, day: 16, hour: 21)
        let night = try XCTUnwrap(schedule.phase(at: evening))
        XCTAssertTrue(night.isNight)
        XCTAssertEqual(night.since, try date(calendar, day: 16, hour: 19, minute: 31))
        XCTAssertEqual(night.until, try date(calendar, day: 17, hour: 7, minute: 14))
    }
}
