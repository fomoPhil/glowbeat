import Foundation

/// Every string the Schedule pane prints, and the two conversions its time pickers need.
///
/// Pure and locale explicit, so a caption can be read in a test on a machine in any time
/// zone, and so the window, the sidebar and the Settings tab cannot end up with three
/// slightly different ways of saying the same thing.
enum ScheduleFormatting {

    // MARK: Clock times

    /// "6:30 AM" in a locale that writes it that way, "06:30" in one that does not.
    static func clockTime(_ time: TimeOfDay,
                          calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        clockTime(date(for: time, calendar: calendar), calendar: calendar, locale: locale)
    }

    static func clockTime(_ date: Date,
                          calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: What a `DatePicker` needs

    /// `DatePicker` deals in dates, and a wake time is an hour and a minute with no day
    /// attached. Today's date carries it, which is enough for `.hourAndMinute`: nothing
    /// ever reads the day part back.
    static func date(for time: TimeOfDay,
                     calendar: Calendar = .autoupdatingCurrent,
                     now: Date = Date()) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)
            ?? now
    }

    static func timeOfDay(from date: Date,
                          calendar: Calendar = .autoupdatingCurrent) -> TimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    // MARK: Readouts

    /// A ramp length. Zero is not "0 min": a ramp of no minutes is the light landing at
    /// once, and that is what it should say.
    static func minutes(_ value: Double) -> String {
        let whole = Int(value.rounded())
        return whole <= 0 ? "instant" : "\(whole) min"
    }

    /// A whole percentage, for the wake brightness.
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    // MARK: The live line

    /// "Next: wake 6:30 AM tomorrow." Nil when the schedule is switched off, which is
    /// what `ScheduleEngine.nextEvent` returns then.
    static func nextEventLine(_ event: ScheduleEngine.Event?,
                              at now: Date,
                              calendar: Calendar = .autoupdatingCurrent,
                              locale: Locale = .autoupdatingCurrent) -> String? {
        guard let event else { return nil }
        let noun = event.kind == .wake ? "wake" : "sleep"
        let time = clockTime(event.date, calendar: calendar, locale: locale)
        return "Next: \(noun) \(time) \(when(event, at: now, calendar: calendar, locale: locale))."
    }

    /// Today, tonight or tomorrow. A sleep that lands later the same day is "tonight",
    /// because that is what a person would call it; a wake that lands later the same day
    /// is "today", because a wake at four in the afternoon is not tonight.
    private static func when(_ event: ScheduleEngine.Event,
                             at now: Date,
                             calendar: Calendar,
                             locale: Locale) -> String {
        if calendar.isDate(event.date, inSameDayAs: now) {
            return event.kind == .sleep ? "tonight" : "today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(event.date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        // Both timers come round every day, so this is unreachable through the engine.
        // It is here because a weekday reads better than an empty word if it ever is.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: event.date)
    }

    // MARK: The light mode caption

    /// What the Light card says under its picker: which white is in force, and what is
    /// deciding it.
    static func lightModeCaption(_ status: LightModeEngine.Status,
                                 at now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent,
                                 locale: Locale = .autoupdatingCurrent) -> String {
        let body = following(status, calendar: calendar, locale: locale)
        guard status.isShifting else { return body }
        // A shift in flight is the one thing the caption says about the room rather than
        // about the schedule, so it goes first.
        return "Shifting to \(status.isWarm ? "warm" : "cool") now. \(body)"
    }

    private static func following(_ status: LightModeEngine.Status,
                                  calendar: Calendar,
                                  locale: Locale) -> String {
        let white = status.isWarm ? "warm" : "cool"
        switch status.origin {
        case .fixed:
            let kelvin = status.mode.fixedKelvin ?? status.kelvin
            return "A \(white) white, \(kelvin) K. Nothing changes it on its own."
        case .nightShift:
            guard let next = status.nextChange else {
                return "Following Night Shift: \(white)."
            }
            return "Following Night Shift: \(white) until "
                + "\(clockTime(next, calendar: calendar, locale: locale))."
        case .sun:
            guard let next = status.nextChange else {
                return "Following the sun: \(white)."
            }
            // Warm runs from sunset to sunrise, so the edge ahead of a warm room is
            // sunrise and the edge ahead of a cool one is sunset.
            let edge = status.isWarm ? "sunrise" : "sunset"
            return "Following the sun: \(white) until \(edge) "
                + "\(clockTime(next, calendar: calendar, locale: locale))."
        case .unavailable:
            return "Night Shift is not available on this Mac, so Auto is holding Daylight."
        }
    }
}
