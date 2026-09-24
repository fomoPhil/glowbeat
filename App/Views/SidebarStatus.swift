import Effects
import Foundation

/// The second line under each sidebar title: what that pane is doing right now.
///
/// Pure functions rather than four computed properties on `AppModel`, for the reason the
/// login item note is pure: a line of text is worth reading in a test without a socket, a
/// store and a room of bulbs standing behind it. `AppModel` holds the one place that
/// feeds them the live values.
enum SidebarStatus {

    /// "6 on" while the whole room is lit, "2 of 6 on" otherwise. A bulb Glowbeat has
    /// never had a status reply from counts as off, because a bulb nobody can see is not
    /// something to claim is lit.
    static func bulbs(total: Int, on: Int) -> String {
        guard total > 0 else { return "No bulbs" }
        return on == total ? "\(total) on" : "\(on) of \(total) on"
    }

    /// "On, Pulse, Punchy": what is running, the effect it is running, and the feel it is
    /// running it with. Custom is a feel too, so it is named rather than left out.
    static func party(state: PartyEngine.State,
                      effect: EffectKind,
                      feel: PartyPreset?) -> String {
        switch state {
        case .off:
            return "Off"
        case .paused:
            // The reason is a sentence and the sidebar is 200 points wide. The banner at
            // the top of the window is where the reason belongs.
            return "Paused"
        case .running:
            return "On, \(effect.displayName), \(feel?.displayName ?? "Custom")"
        }
    }

    /// The scene only gets named while it is painting. Naming the remembered scene while
    /// nothing is running would read as something being on.
    static func scenes(isRunning: Bool, kind: SceneKind) -> String {
        isRunning ? kind.displayName : "Off"
    }

    /// "Golden hour, 70%" while a still color is on the room, "Off" otherwise.
    ///
    /// The applied color rather than the picked one. The pane rings the last swatch
    /// somebody chose whatever the bulbs are doing, because that is a memory of a choice;
    /// this line claims the room is wearing it, which is only true until something else
    /// paints over it.
    static func colors(applied: StillColor?, brightness: Double) -> String {
        guard let applied else { return "Off" }
        return "\(applied.name), \(StillColor.brightnessPercent(brightness))%"
    }

    static func schedule(_ schedule: ScheduleSettings,
                         locale: Locale = .autoupdatingCurrent,
                         calendar: Calendar = .autoupdatingCurrent) -> String {
        guard schedule.isEnabled else { return "Off" }
        let wake = ScheduleFormatting.clockTime(schedule.wakeTime,
                                                calendar: calendar,
                                                locale: locale)
        let sleep = ScheduleFormatting.clockTime(schedule.sleepTime,
                                                 calendar: calendar,
                                                 locale: locale)
        return "Wake \(wake), sleep \(sleep)"
    }
}
