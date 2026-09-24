import XCTest
import AppKit
import SwiftUI
import GoveeLAN
@testable import Glowbeat

/// The Schedule pane and the Settings tab that mirrors it: every control round trips to
/// the stored settings, and every line of text the pane prints is worked out by a pure
/// function that can be read without rendering anything.
@MainActor
final class SchedulePaneTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var defaults: UserDefaults!

    private func makeModel() throws -> AppModel {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        if defaults == nil {
            suiteName = "glowbeat.tests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }
        return AppModel(socket: socket,
                        discovery: BulbDiscovery(socket: socket, configuration: configuration),
                        controller: BulbController(socket: socket),
                        poller: StatusPoller(socket: socket, configuration: configuration),
                        frameSource: ScriptedFrameSource(),
                        tickSource: ManualTickSource(),
                        settingsStore: SettingsStore(defaults: defaults),
                        nameStore: BulbNameStore(defaults: defaults),
                        loginItems: FakeLoginItemService())
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        defaults = nil
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private static let locale = Locale(identifier: "en_US")

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "America/Denver") ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute)) ?? .distantPast
    }

    // MARK: Every control round trips

    func testEveryControlOnThePaneReachesTheStoredSettings() throws {
        let model = try makeModel()

        model.setLightMode(.night)
        model.setShiftLength(minutes: 45)
        model.setScheduleEnabled(true)
        model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        model.setSleepTime(TimeOfDay(hour: 23, minute: 15))
        model.setWakeRamp(minutes: 15)
        model.setSleepRamp(minutes: 20)
        model.setWakeBrightness(70)

        socket.stop()
        let fresh = try makeModel()
        XCTAssertEqual(fresh.lightMode, .night)
        XCTAssertEqual(fresh.settings.shiftLengthMinutes, 45)
        XCTAssertTrue(fresh.scheduleSettings.isEnabled)
        XCTAssertEqual(fresh.scheduleSettings.wakeTime, TimeOfDay(hour: 6, minute: 30))
        XCTAssertEqual(fresh.scheduleSettings.sleepTime, TimeOfDay(hour: 23, minute: 15))
        XCTAssertEqual(fresh.scheduleSettings.wakeRampMinutes, 15)
        XCTAssertEqual(fresh.scheduleSettings.sleepRampMinutes, 20)
        XCTAssertEqual(fresh.scheduleSettings.wakeBrightness, 70)
    }

    /// The sliders drag live and only write on release, the way every other slider in the
    /// app does. Dragging one has to be visible in the settings the pane reads back.
    func testDraggingASliderAppliesLiveAndCommitsOnlyOnRelease() throws {
        let model = try makeModel()
        model.setWakeRamp(minutes: 30, persist: false)
        XCTAssertEqual(model.scheduleSettings.wakeRampMinutes, 30)
        XCTAssertNotEqual(defaults.integer(forKey: "scheduleWakeRampMinutes"), 30,
                          "A drag wrote to disk before it was let go.")
        model.setWakeRamp(minutes: 30)
        XCTAssertEqual(defaults.integer(forKey: "scheduleWakeRampMinutes"), 30)
    }

    func testTheSlidersClampToTheirRanges() throws {
        let model = try makeModel()
        model.setShiftLength(minutes: -5)
        XCTAssertEqual(model.settings.shiftLengthMinutes, 0)
        model.setShiftLength(minutes: 500)
        XCTAssertEqual(model.settings.shiftLengthMinutes, 120)
        model.setWakeRamp(minutes: 900)
        XCTAssertEqual(model.scheduleSettings.wakeRampMinutes, 60)
        model.setSleepRamp(minutes: -1)
        XCTAssertEqual(model.scheduleSettings.sleepRampMinutes, 0)
        model.setWakeBrightness(0)
        XCTAssertEqual(model.scheduleSettings.wakeBrightness, 1,
                       "Zero is what a bulb reports when it is off, so a wake never ends there.")
    }

    // MARK: A time picker is a Date on the screen and an hour and a minute underneath

    func testTheTimePickerRoundTripsThroughADate() {
        let calendar = Self.calendar
        for (hour, minute) in [(0, 0), (6, 30), (12, 0), (13, 45), (23, 59)] {
            let time = TimeOfDay(hour: hour, minute: minute)
            let date = ScheduleFormatting.date(for: time, calendar: calendar)
            XCTAssertEqual(ScheduleFormatting.timeOfDay(from: date, calendar: calendar), time)
        }
    }

    // MARK: The readouts

    func testTheMinutesReadoutSaysInstantAtZero() {
        XCTAssertEqual(ScheduleFormatting.minutes(0), "instant")
        XCTAssertEqual(ScheduleFormatting.minutes(1), "1 min")
        XCTAssertEqual(ScheduleFormatting.minutes(30), "30 min")
        XCTAssertEqual(ScheduleFormatting.minutes(120), "120 min")
    }

    /// The readouts are drawn in SF Mono, which is wider than the face the labels use, so
    /// the widest string each column can print is measured in the face that prints it.
    func testEveryScheduleReadoutFitsItsColumn() {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        var readouts = [ScheduleFormatting.minutes(0), ScheduleFormatting.minutes(120)]
        readouts += [ScheduleFormatting.percent(1), ScheduleFormatting.percent(100)]
        for readout in readouts {
            let width = (readout as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, LabeledValueSlider.readoutWidthDefault,
                                     "\(readout) does not fit the readout column.")
        }
    }

    func testEveryScheduleLabelFitsTheSharedColumn() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for label in ["Shift over", "Light up over", "To", "Dim over"] {
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, LabeledValueSlider.labelWidth,
                                     "\(label) does not fit the label column.")
        }
    }

    // MARK: The live "Next" line

    func testTheNextLineNamesTheEventAndWhen() {
        let calendar = Self.calendar
        let now = Self.date(2026, 9, 16, 20, 0)

        let wakeTomorrow = ScheduleEngine.Event(kind: .wake,
                                                date: Self.date(2026, 9, 17, 6, 30))
        XCTAssertEqual(ScheduleFormatting.nextEventLine(wakeTomorrow, at: now,
                                                        calendar: calendar, locale: Self.locale),
                       "Next: wake 6:30\u{202F}AM tomorrow.")

        let sleepTonight = ScheduleEngine.Event(kind: .sleep,
                                                date: Self.date(2026, 9, 16, 23, 0))
        XCTAssertEqual(ScheduleFormatting.nextEventLine(sleepTonight, at: now,
                                                        calendar: calendar, locale: Self.locale),
                       "Next: sleep 11:00\u{202F}PM tonight.")

        let wakeToday = ScheduleEngine.Event(kind: .wake, date: Self.date(2026, 9, 16, 22, 0))
        XCTAssertEqual(ScheduleFormatting.nextEventLine(wakeToday, at: now,
                                                        calendar: calendar, locale: Self.locale),
                       "Next: wake 10:00\u{202F}PM today.")

        let farOff = ScheduleEngine.Event(kind: .sleep, date: Self.date(2026, 9, 19, 23, 0))
        XCTAssertEqual(ScheduleFormatting.nextEventLine(farOff, at: now,
                                                        calendar: calendar, locale: Self.locale),
                       "Next: sleep 11:00\u{202F}PM Saturday.")

        XCTAssertNil(ScheduleFormatting.nextEventLine(nil, at: now,
                                                      calendar: calendar, locale: Self.locale),
                     "A switched off schedule has no next event to print.")
    }

    /// The line the pane draws comes from the engine rather than from a second copy of
    /// the same arithmetic.
    func testTheNextLineMatchesTheEngine() throws {
        let model = try makeModel()
        XCTAssertNil(model.nextScheduleEvent)
        model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        model.setSleepTime(TimeOfDay(hour: 23, minute: 0))
        model.setScheduleEnabled(true)
        let event = try XCTUnwrap(model.nextScheduleEvent)
        XCTAssertTrue(event.date > Date())
        let line = try XCTUnwrap(ScheduleFormatting.nextEventLine(event, at: Date()))
        XCTAssertTrue(line.hasPrefix("Next: "), "The line reads \(line).")
    }

    // MARK: The light mode caption

    func testTheCaptionSaysWhatTheModeIsFollowing() {
        let calendar = Self.calendar
        let now = Self.date(2026, 9, 16, 20, 0)

        func caption(_ status: LightModeEngine.Status) -> String {
            ScheduleFormatting.lightModeCaption(status, at: now,
                                                calendar: calendar, locale: Self.locale)
        }

        XCTAssertEqual(caption(.init(mode: .daylight, origin: .fixed, isWarm: false,
                                     kelvin: 6000, nextChange: nil, isShifting: false)),
                       "A cool white, 6000 K. Nothing changes it on its own.")
        XCTAssertEqual(caption(.init(mode: .night, origin: .fixed, isWarm: true,
                                     kelvin: 2700, nextChange: nil, isShifting: false)),
                       "A warm white, 2700 K. Nothing changes it on its own.")

        XCTAssertEqual(caption(.init(mode: .auto, origin: .nightShift, isWarm: true,
                                     kelvin: 2700,
                                     nextChange: Self.date(2026, 9, 17, 7, 0),
                                     isShifting: false)),
                       "Following Night Shift: warm until 7:00\u{202F}AM.")
        XCTAssertEqual(caption(.init(mode: .auto, origin: .nightShift, isWarm: false,
                                     kelvin: 6000, nextChange: nil, isShifting: false)),
                       "Following Night Shift: cool.")

        XCTAssertEqual(caption(.init(mode: .auto, origin: .sun, isWarm: false, kelvin: 6000,
                                     nextChange: Self.date(2026, 9, 16, 19, 32),
                                     isShifting: false)),
                       "Following the sun: cool until sunset 7:32\u{202F}PM.")
        XCTAssertEqual(caption(.init(mode: .auto, origin: .sun, isWarm: true, kelvin: 2700,
                                     nextChange: Self.date(2026, 9, 17, 6, 42),
                                     isShifting: false)),
                       "Following the sun: warm until sunrise 6:42\u{202F}AM.")

        XCTAssertEqual(caption(.init(mode: .auto, origin: .unavailable, isWarm: false,
                                     kelvin: 6000, nextChange: nil, isShifting: false)),
                       "Night Shift is not available on this Mac, so Auto is holding Daylight.")
    }

    /// A shift in flight is the one thing the caption says about the room rather than
    /// about the schedule, so it is said first.
    func testAShiftInFlightIsSaidFirst() {
        let status = LightModeEngine.Status(mode: .auto, origin: .nightShift, isWarm: true,
                                            kelvin: 3400, nextChange: nil, isShifting: true)
        let caption = ScheduleFormatting.lightModeCaption(status, at: Date(),
                                                          calendar: Self.calendar,
                                                          locale: Self.locale)
        XCTAssertEqual(caption, "Shifting to warm now. Following Night Shift: warm.")
    }

    /// The model hands the pane the caption, so the pane and the sidebar cannot disagree.
    func testTheModelAnswersWithACaption() throws {
        let model = try makeModel()
        XCTAssertEqual(model.lightModeCaption,
                       "A cool white, 6000 K. Nothing changes it on its own.")
        model.setLightMode(.night)
        XCTAssertEqual(model.lightModeCaption,
                       "A warm white, 2700 K. Nothing changes it on its own.")
    }

    // MARK: The two things a timer cannot do for itself

    func testThePaneSaysWhatItCannotDo() {
        XCTAssertEqual(SchedulePanelView.macAwakeNote,
                       "Timers run while this Mac is awake. If it was asleep, the lights "
                       + "catch up when it wakes.")
        XCTAssertEqual(SchedulePanelView.bulbPowerNote,
                       "Bulbs need power to wake. Keep their switch on.")
    }

    /// The first run guide has one sentence about it, so somebody who never opens the
    /// pane still knows the feature is there.
    func testTheFirstRunGuideMentionsTheSchedule() {
        XCTAssertTrue(FirstRunSheet.scheduleSentence.contains("Schedule"))
        XCTAssertFalse(FirstRunSheet.scheduleSentence.isEmpty)
    }

    // MARK: Rendering

    func testThePaneAndItsSettingsTabRender() throws {
        let model = try makeModel()
        for mode in LightMode.allCases {
            model.setLightMode(mode)
            let pane = ImageRenderer(content: SchedulePanelView(model: model).frame(width: 760))
            XCTAssertNotNil(pane.nsImage, "The pane did not lay out on \(mode.displayName).")
        }
        model.setScheduleEnabled(true)
        let enabled = ImageRenderer(content: SchedulePanelView(model: model).frame(width: 760))
        XCTAssertNotNil(enabled.nsImage)

        let tab = ImageRenderer(content: ScheduleSettingsTab(model: model)
            .frame(width: 460, height: 620))
        XCTAssertNotNil(tab.nsImage)

        let settings = ImageRenderer(content: SettingsView(model: model)
            .frame(width: 520, height: 620))
        XCTAssertNotNil(settings.nsImage)
    }
}
