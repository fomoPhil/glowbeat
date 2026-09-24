import Foundation

/// The five things the window can be showing, which is also the five rows in the sidebar.
///
/// The window used to be one long scroller with two collapsible panels in it. Phil picked
/// layout B on 2026-09-16 (`docs/design/mockups/layout-b-sidebar.html`), so each of those
/// panels is now a pane of its own and the bulb list is the third. Colors joined them on
/// 2026-09-17. Stored as a raw value so which pane the window was left on stays a plist
/// string like every other setting.
///
/// The order is the order the panes read in: the bulbs themselves, then the three ways to
/// light them, loudest first, then when it happens without anyone asking. Colors sits
/// between Scenes and Schedule because it is the quietest of the three and the closest
/// thing to the white the Schedule holds.
enum SidebarPane: String, CaseIterable, Identifiable, Sendable {
    case bulbs
    case party
    case scenes
    case colors
    case schedule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bulbs: return "Bulbs"
        case .party: return "Party"
        case .scenes: return "Scenes"
        case .colors: return "Colors"
        case .schedule: return "Schedule"
        }
    }

    /// The symbol beside the title. `waveform` is the one the Party Mode switch already
    /// wears and `moon.stars` the one on the Scenes switch, so the sidebar names the same
    /// things the controls do.
    var symbol: String {
        switch self {
        case .bulbs: return "lightbulb"
        case .party: return "waveform"
        case .scenes: return "moon.stars"
        case .colors: return "paintpalette"
        case .schedule: return "clock"
        }
    }

    /// The Bulbs pane is the list, so the strip under it would be a second copy of every
    /// control already on screen. Every other pane keeps it, which is the whole point of
    /// a strip: the bulbs stay reachable wherever you are.
    var showsBulbStrip: Bool {
        self != .bulbs
    }
}
