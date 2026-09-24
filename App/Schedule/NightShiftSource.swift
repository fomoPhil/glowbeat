import Foundation

/// Night Shift's own daily window, as the OS stores it.
struct NightShiftSchedule: Equatable, Sendable {
    var from: TimeOfDay
    var to: TimeOfDay
}

/// What the Mac says about Night Shift right now.
///
/// The field names follow the private struct's own layout, documented in the research
/// (section A2) and cross checked against Shifty's published header. Only `isEnabled` is
/// ever acted on; the rest is kept because a status that only carried one flag would
/// have to be re-read to answer any other question.
struct NightShiftStatus: Equatable, Sendable {

    enum Mode: Int, Sendable {
        /// No schedule. Night Shift is off unless somebody switched it on by hand.
        case none = 0
        case sunsetToSunrise = 1
        case custom = 2
    }

    /// The OS's `active` flag. Deliberately never read: on the machine the research was
    /// run on it was 1 while Night Shift was off and the screen was untinted, so it is
    /// not the "is the screen warm right now" flag it looks like. `isEnabled` is.
    /// Research section A4.
    var isActive: Bool
    /// The flag Glowbeat follows. It flips instantly at a scheduled edge, before the
    /// OS's own 120 second screen fade has started.
    var isEnabled: Bool
    var isSunSchedulePermitted: Bool
    /// Kept raw. A mode this build has never heard of must not be guessed at.
    var rawMode: Int
    var schedule: NightShiftSchedule

    var mode: Mode? {
        Mode(rawValue: rawMode)
    }
}

/// The Mac's own sunrise and sunset times, as `BlueLightSunSchedule` reports them.
struct SunSchedule: Equatable, Sendable {

    var previousSunrise: Date
    var sunrise: Date
    var nextSunrise: Date
    var previousSunset: Date
    var sunset: Date
    var nextSunset: Date

    /// Which side of the sun a moment falls on, when it began and when it ends.
    ///
    /// The six times are put in order and the pair either side of `now` is found, rather
    /// than the three named "current" ones being trusted to bracket it: the OS reports
    /// them from its own idea of today, and a Mac that has been asleep across a day
    /// boundary can hand back a set that does not.
    func phase(at now: Date) -> (isNight: Bool, since: Date, until: Date)? {
        let events: [(date: Date, isSunset: Bool)] = [
            (previousSunrise, false),
            (sunrise, false),
            (nextSunrise, false),
            (previousSunset, true),
            (sunset, true),
            (nextSunset, true)
        ].sorted { $0.date < $1.date }
        guard let index = events.lastIndex(where: { $0.date <= now }),
              index + 1 < events.count else { return nil }
        return (isNight: events[index].isSunset,
                since: events[index].date,
                until: events[index + 1].date)
    }
}

/// Read only access to Night Shift. Nothing behind this protocol may ever set anything:
/// Glowbeat follows the Mac's setting, it does not change it.
@MainActor
protocol NightShiftSource: AnyObject {

    /// Called when the OS reports that something about Night Shift changed. It fires per
    /// mutation rather than per logical change, so the engine treats it as a hint to
    /// re-read rather than as an event in itself.
    var onChange: (@MainActor () -> Void)? { get set }

    /// Nil when the private API did not answer, which is the only availability check
    /// worth making: the class resolves and `supportsBlueLightReduction` returns true
    /// even where the calls themselves fail. Research section A7.
    func readStatus() -> NightShiftStatus?

    func readSunSchedule() -> SunSchedule?

    func startObserving()
    func stopObserving()
}
