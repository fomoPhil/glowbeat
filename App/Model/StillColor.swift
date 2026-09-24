import Effects
import Foundation

/// The four headings the Colors pane draws, in the order it draws them.
///
/// Whites first because a room light is a white light most of the time, then the three
/// groups of color: the ones a sky does, the ones a room can sit in all evening, and the
/// ones that are simply loud.
enum StillColorGroup: String, CaseIterable, Identifiable, Sendable {
    case whites
    case sky
    case mood
    case playful

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whites: return "Whites"
        case .sky: return "Sky"
        case .mood: return "Mood"
        case .playful: return "Playful"
        }
    }
}

/// One color from the curated catalog: a name, the group it is filed under, and either a
/// white temperature or a color.
///
/// Phil, 2026-09-17: "a whole bunch of color presets for daylight, evening, etc ...
/// individual static colors and a brightness slider so you can easily pick a color,
/// choose the brightness, and move on with life."
///
/// Not a scene and not an effect. Nothing about a still color ticks: applying one is
/// three commands and then silence, so the room holds that color until somebody, or the
/// next Light transition, changes it. That is also why this is a value rather than a
/// renderer: there is nothing to run.
struct StillColor: Identifiable, Hashable, Sendable {

    /// A white goes out as `colorwc` with a Kelvin; a color goes out as `colorwc` with
    /// an RGB triple. The bulb can only be in one of the two modes, which is exactly why
    /// the two are one enum rather than two optional properties that could both be set.
    enum Value: Hashable, Sendable {
        /// Held inside the H6004's own 2700 to 6500 K range.
        case white(kelvin: Int)
        case rgb(Effects.RGB)
    }

    let id: String
    let name: String
    let group: StillColorGroup
    let value: Value

    private init(id: String, name: String, group: StillColorGroup, kelvin: Int) {
        self.id = id
        self.name = name
        self.group = group
        self.value = .white(kelvin: WhiteTemperature.clamped(kelvin))
    }

    private init(id: String, name: String, group: StillColorGroup, hex: UInt32) {
        self.id = id
        self.name = name
        self.group = group
        self.value = .rgb(Effects.RGB(hex: hex))
    }

    // MARK: The catalog

    /// Whites, by the light they are named after.
    ///
    /// Daylight is `WhiteTemperature.daylightKelvin` rather than a second 6000 written
    /// out here, so the swatch in this pane and the Daylight on the Schedule pane's Light
    /// card can never drift into being two different whites. Candle is the bulb's warm
    /// end and Overcast its cool end, so the row spans everything the H6004 can do.
    static let daylight = StillColor(id: "daylight", name: "Daylight",
                                     group: .whites, kelvin: WhiteTemperature.daylightKelvin)
    static let overcast = StillColor(id: "overcast", name: "Overcast",
                                     group: .whites, kelvin: 6500)
    static let studio = StillColor(id: "studio", name: "Studio",
                                   group: .whites, kelvin: 5000)
    static let neutral = StillColor(id: "neutral", name: "Neutral",
                                    group: .whites, kelvin: 4000)
    static let warm = StillColor(id: "warm", name: "Warm",
                                 group: .whites, kelvin: 3000)
    static let candle = StillColor(id: "candle", name: "Candle",
                                   group: .whites, kelvin: 2700)

    // Sky. Tuned for an RGB bulb rather than for a screen, which is a real difference:
    // a bulb oversaturates, so a pale sky color needs all three channels high or it
    // lands as a flat wash of its strongest one, and a deep one needs a little of the
    // other two or it lands as pure red, green or blue. Same lesson the Blacklight
    // palette learned (`Palette.blacklight`): 0x3A00FF reads as plain blue in a room.

    /// Peach, lifted toward pink rather than toward orange: the blue channel is what
    /// keeps it from being another amber next to Golden hour.
    static let sunrise = StillColor(id: "sunrise", name: "Sunrise",
                                    group: .sky, hex: 0xFF9E7A)
    /// The hour itself: amber with the green pulled down so it reads as gold and not as
    /// the yellow in the middle of the Party palette.
    static let goldenHour = StillColor(id: "golden-hour", name: "Golden hour",
                                       group: .sky, hex: 0xFFA114)
    /// Rose on its way into violet, which is the moment the brief names.
    static let dusk = StillColor(id: "dusk", name: "Dusk", group: .sky, hex: 0xC85A96)
    /// Dusty rather than electric: the blue is well short of full and the red and green
    /// are close together, which is what greys it.
    static let twilight = StillColor(id: "twilight", name: "Twilight",
                                     group: .sky, hex: 0x6A6BB4)
    /// A white with a lean, not a blue. All three channels high, blue highest.
    static let moonlight = StillColor(id: "moonlight", name: "Moonlight",
                                      group: .sky, hex: 0xC8DCFF)
    /// Deep navy, kept off a pure blue so a bulb still shows some body in it.
    static let midnight = StillColor(id: "midnight", name: "Midnight",
                                     group: .sky, hex: 0x1E3C8C)

    // Mood.

    /// The Party palette's own UV violet, so the two features mean the same thing by the
    /// word.
    static let blacklight = StillColor(id: "blacklight", name: "Blacklight",
                                       group: .mood, hex: 0x6A00FF)
    static let lava = StillColor(id: "lava", name: "Lava", group: .mood, hex: 0xFF3C0A)
    /// The same fire, banked: the channels are the same shape as Lava at about two
    /// thirds the level, which is what makes it read as dim rather than as brown.
    static let ember = StillColor(id: "ember", name: "Ember", group: .mood, hex: 0xB4500F)
    static let lavender = StillColor(id: "lavender", name: "Lavender",
                                     group: .mood, hex: 0xB48CFF)
    static let rose = StillColor(id: "rose", name: "Rose", group: .mood, hex: 0xFF5A82)
    static let mint = StillColor(id: "mint", name: "Mint", group: .mood, hex: 0x6EF0BE)
    static let ocean = StillColor(id: "ocean", name: "Ocean", group: .mood, hex: 0x00A0BE)
    static let forest = StillColor(id: "forest", name: "Forest", group: .mood, hex: 0x1E9646)
    static let ice = StillColor(id: "ice", name: "Ice", group: .mood, hex: 0xD2F5FF)

    // Playful. The only group allowed to be neon, because its names say so.

    static let neonPink = StillColor(id: "neon-pink", name: "Neon pink",
                                     group: .playful, hex: 0xFF1493)
    static let electricBlue = StillColor(id: "electric-blue", name: "Electric blue",
                                         group: .playful, hex: 0x0064FF)
    static let lime = StillColor(id: "lime", name: "Lime", group: .playful, hex: 0x8CFF14)
    static let tangerine = StillColor(id: "tangerine", name: "Tangerine",
                                      group: .playful, hex: 0xFF7800)
    static let grape = StillColor(id: "grape", name: "Grape",
                                  group: .playful, hex: 0x8C28DC)

    /// Every color, in the order the pane draws them: group by group, and inside a group
    /// in the order the group's own story runs.
    static let all: [StillColor] = [
        daylight, overcast, studio, neutral, warm, candle,
        sunrise, goldenHour, dusk, twilight, moonlight, midnight,
        blacklight, lava, ember, lavender, rose, mint, ocean, forest, ice,
        neonPink, electricBlue, lime, tangerine, grape
    ]

    static func colors(in group: StillColorGroup) -> [StillColor] {
        all.filter { $0.group == group }
    }

    /// Nil for an id this build does not know, which is what a hand edited store or a
    /// catalog from a later version looks like.
    static func color(withID id: String?) -> StillColor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // MARK: Brightness

    /// What a fresh install picks up at. Bright enough to light a room, short of the top
    /// so the slider visibly has somewhere to go in both directions.
    static let defaultBrightness: Double = 0.7

    /// One percent, not zero. Zero is a bulb that is off, which is not a brightness
    /// anyone chose, and a Colors pane that could switch the room off through its
    /// brightness slider would be a switch wearing a slider's clothes.
    static let minimumBrightness: Double = 0.01

    static func clampedBrightness(_ value: Double) -> Double {
        // A drag cannot produce one, but a hand edited store can, and `min`/`max` carry
        // a `nan` straight through.
        guard !value.isNaN else { return defaultBrightness }
        return min(1, max(minimumBrightness, value))
    }

    /// What goes on the wire: the 1 through 100 the `brightness` command takes.
    static func brightnessPercent(_ value: Double) -> Int {
        min(100, max(1, Int((clampedBrightness(value) * 100).rounded())))
    }
}
