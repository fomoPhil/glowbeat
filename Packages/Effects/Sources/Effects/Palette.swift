import Foundation

/// A named set of beat colors plus the dim color bulbs rest at between beats.
public struct Palette: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Four to six colors, used in order as beats arrive.
    public var colors: [RGB]
    /// Where bulbs sit when nothing is happening. Also the color Party Mode leaves
    /// bulbs at when it is switched off.
    public var dimBase: RGB

    public init(id: String, name: String, colors: [RGB], dimBase: RGB) {
        self.id = id
        self.name = name
        self.colors = colors
        self.dimBase = dimBase
    }

    public static let party = Palette(
        id: "party",
        name: "Party",
        colors: [RGB(hex: 0xFF0044), RGB(hex: 0xFF9500), RGB(hex: 0xFFE800),
                 RGB(hex: 0x00E5FF), RGB(hex: 0xB026FF)],
        dimBase: RGB(hex: 0x14000A))

    public static let sunset = Palette(
        id: "sunset",
        name: "Sunset",
        colors: [RGB(hex: 0xFF4E00), RGB(hex: 0xFF8C42), RGB(hex: 0xFFC15E),
                 RGB(hex: 0xC2185B), RGB(hex: 0x6A1B9A)],
        dimBase: RGB(hex: 0x1A0A06))

    public static let ocean = Palette(
        id: "ocean",
        name: "Ocean",
        colors: [RGB(hex: 0x00B4D8), RGB(hex: 0x0077B6), RGB(hex: 0x48CAE4),
                 RGB(hex: 0x90E0EF), RGB(hex: 0x023E8A)],
        dimBase: RGB(hex: 0x02121C))

    public static let neon = Palette(
        id: "neon",
        name: "Neon",
        colors: [RGB(hex: 0x39FF14), RGB(hex: 0xFF073A), RGB(hex: 0x00F0FF),
                 RGB(hex: 0xFF00E6), RGB(hex: 0xFAFF00)],
        dimBase: RGB(hex: 0x0A0A14))

    public static let warmWhite = Palette(
        id: "warm-white",
        name: "Warm white",
        colors: [RGB(hex: 0xFFD9A0), RGB(hex: 0xFFC97A), RGB(hex: 0xFFE7C4),
                 RGB(hex: 0xFFB85C)],
        dimBase: RGB(hex: 0x2A1A0A))

    /// UV club light. Deep violets with no green at all, so the room reads as blacklight
    /// rather than as a blue wash.
    public static let blacklight = Palette(
        id: "blacklight",
        name: "Blacklight",
        // The two bluest entries carry a little more red than the spec's first draft:
        // 0x3A00FF and 0x2200AA read as plain blue on an RGB bulb, which is not what a
        // blacklight looks like in a room.
        colors: [RGB(hex: 0x5A00FF), RGB(hex: 0x6A00FF), RGB(hex: 0x8F00FF),
                 RGB(hex: 0xB400FF), RGB(hex: 0x3A00C8)],
        dimBase: RGB(hex: 0x0A0018))

    public static let forest = Palette(
        id: "forest",
        name: "Forest",
        colors: [RGB(hex: 0x2F7A3E), RGB(hex: 0x6AA84F), RGB(hex: 0x0F766E),
                 RGB(hex: 0x14B8A6), RGB(hex: 0xC98A2B)],
        dimBase: RGB(hex: 0x040E08))

    public static let candy = Palette(
        id: "candy",
        name: "Candy",
        colors: [RGB(hex: 0xFF5FA2), RGB(hex: 0xFF2DAF), RGB(hex: 0xFF7A5C),
                 RGB(hex: 0x7CF3C4), RGB(hex: 0xFFF07C)],
        dimBase: RGB(hex: 0x180410))

    public static let ice = Palette(
        id: "ice",
        name: "Ice",
        colors: [RGB(hex: 0xE8F6FF), RGB(hex: 0x9FE8FF), RGB(hex: 0x66D9FF),
                 RGB(hex: 0xC6C9FF)],
        dimBase: RGB(hex: 0x050D14))

    public static let fire = Palette(
        id: "fire",
        name: "Fire",
        colors: [RGB(hex: 0xFF2A00), RGB(hex: 0xFF6A00), RGB(hex: 0xFFA200),
                 RGB(hex: 0xFFD000)],
        dimBase: RGB(hex: 0x1A0500))

    /// The order the picker shows them in. The five v1 palettes come first so nobody's
    /// picker rearranges itself under them after an update.
    public static let all: [Palette] = [party, sunset, ocean, neon, warmWhite,
                                        blacklight, forest, candy, ice, fire]

    /// Returns the palette with that id, or Party when the id is unknown.
    public static func palette(withID id: String) -> Palette {
        all.first { $0.id == id } ?? party
    }
}
