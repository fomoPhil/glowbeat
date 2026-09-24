import Foundation

/// An hour and a minute, with no day attached. What a wake or sleep timer is set to.
struct TimeOfDay: Equatable, Comparable, Sendable {

    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    var minutesFromMidnight: Int {
        hour * 60 + minute
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }

    /// The `DateComponents` both lookups match on. Seconds are pinned to zero so a timer
    /// set to 06:30 means 06:30:00 rather than any second inside that minute.
    private var components: DateComponents {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        return components
    }

    /// The first time this hour and minute comes round after `date`.
    ///
    /// Through `Calendar` rather than by adding 86,400 seconds, so the two days a year
    /// that are not 24 hours long land on the clock time the user set rather than an
    /// hour either side of it.
    func nextOccurrence(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: date,
                          matching: components,
                          matchingPolicy: .nextTime,
                          direction: .forward)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }

    /// The last time this hour and minute came round at or before `date`.
    ///
    /// `nextDate(direction: .backward)` is strictly earlier than the date it is given, so
    /// a `date` that is exactly this time of day would otherwise return yesterday's
    /// occurrence and a timer would never be seen to fire on the tick it landed on. One
    /// second later is enough to include it.
    func mostRecentOccurrence(onOrBefore date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: date.addingTimeInterval(1),
                          matching: components,
                          matchingPolicy: .nextTime,
                          direction: .backward)
            ?? date.addingTimeInterval(-24 * 60 * 60)
    }
}

/// The wake and sleep timers, as one thing.
///
/// Every day. Days of the week are deliberately out of scope for v1.2: the feature is a
/// bedside lamp, not a calendar.
struct ScheduleSettings: Equatable, Sendable {

    /// Whether either timer runs at all. Off on a fresh install: Glowbeat never starts
    /// changing the room on its own until someone asks it to.
    var isEnabled: Bool
    var wakeTime: TimeOfDay
    var sleepTime: TimeOfDay
    /// Minutes, 0 through 60. Zero means the wake lands in one step.
    var wakeRampMinutes: Int
    /// Minutes, 0 through 60. Zero means the bulbs go straight out.
    var sleepRampMinutes: Int
    /// Percent, 1 through 100. How bright the room ends up at the end of a wake.
    var wakeBrightness: Int

    init(isEnabled: Bool,
         wakeTime: TimeOfDay,
         sleepTime: TimeOfDay,
         wakeRampMinutes: Int,
         sleepRampMinutes: Int,
         wakeBrightness: Int) {
        self.isEnabled = isEnabled
        self.wakeTime = wakeTime
        self.sleepTime = sleepTime
        self.wakeRampMinutes = Self.clampedRampMinutes(wakeRampMinutes)
        self.sleepRampMinutes = Self.clampedRampMinutes(sleepRampMinutes)
        self.wakeBrightness = Self.clampedWakeBrightness(wakeBrightness)
    }

    /// What a fresh install runs on: nothing, set to the hours the Mac's own Night Shift
    /// schedule ships with, so turning the toggle on lands somewhere sensible.
    static let defaults = ScheduleSettings(isEnabled: false,
                                           wakeTime: TimeOfDay(hour: 7, minute: 0),
                                           sleepTime: TimeOfDay(hour: 22, minute: 0),
                                           wakeRampMinutes: 0,
                                           sleepRampMinutes: 0,
                                           wakeBrightness: 100)

    static let maximumRampMinutes = 60

    static func clampedRampMinutes(_ value: Int) -> Int {
        min(maximumRampMinutes, max(0, value))
    }

    /// One percent rather than zero: zero brightness is what the bulb reports when it is
    /// off, so a wake that ended there would be a wake to a dark room.
    static func clampedWakeBrightness(_ value: Int) -> Int {
        min(100, max(1, value))
    }

    var wakeRamp: TimeInterval {
        TimeInterval(wakeRampMinutes) * 60
    }

    var sleepRamp: TimeInterval {
        TimeInterval(sleepRampMinutes) * 60
    }
}
