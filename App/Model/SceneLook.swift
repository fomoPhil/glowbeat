import Effects
import Foundation

/// How one scene looks: a palette or two custom colors, and the brightness range it moves
/// through. Each scene keeps its own, so a dim blue Breathe and a full amber Candle can
/// both be waiting in the picker.
struct SceneLook: Equatable, Sendable {

    /// The palette the scene paints with. Nil until someone picks one for this scene,
    /// which means it follows Party Mode's palette, the way every scene did before scenes
    /// had colors of their own.
    var paletteID: String?
    /// True when the scene paints with `low` and `high` instead of a palette.
    var isCustom: Bool
    /// The color at the low point: the bottom of a breath, a candle's dimmest flicker.
    var low: RGB
    /// The color at the high point.
    var high: RGB
    /// 0 through 1. The Darkest slider.
    var floor: Double
    /// 0 through 1. The Brightest slider.
    var ceiling: Double

    /// The two custom colors a scene that ships on a palette offers when someone first
    /// picks Custom.
    static let defaultLow = RGB(hex: 0x0077B6)
    static let defaultHigh = RGB(hex: 0xB026FF)

    /// What a scene looks like before anyone has changed it, taken from the Effects
    /// package so Candle and Sunset keep the looks they shipped with.
    static func defaults(for kind: SceneKind) -> SceneLook {
        let style = kind.defaultStyle(palette: .party)
        var look = SceneLook(paletteID: nil,
                             isCustom: false,
                             low: defaultLow,
                             high: defaultHigh,
                             floor: style.floor,
                             ceiling: style.ceiling)
        if case .custom(let low, let high) = style.colors {
            look.isCustom = true
            look.low = low
            look.high = high
        }
        return look
    }

    /// The palette this scene paints with, given the one Party Mode is on.
    func palette(following partyPalette: Palette) -> Palette {
        paletteID.map(Palette.palette(withID:)) ?? partyPalette
    }

    func style(following partyPalette: Palette) -> SceneStyle {
        SceneStyle(colors: isCustom ? .custom(low: low, high: high)
                                    : .palette(palette(following: partyPalette)),
                   floor: floor,
                   ceiling: ceiling)
    }
}

extension SceneLook {

    private enum Key {
        static let paletteID = "palette"
        static let isCustom = "custom"
        static let low = "low"
        static let high = "high"
        static let floor = "floor"
        static let ceiling = "ceiling"
    }

    /// A plist dictionary, so the settings store needs nothing to encode it.
    var stored: [String: Any] {
        var values: [String: Any] = [Key.isCustom: isCustom,
                                     Key.low: Self.hex(low),
                                     Key.high: Self.hex(high),
                                     Key.floor: floor,
                                     Key.ceiling: ceiling]
        if let paletteID {
            values[Key.paletteID] = paletteID
        }
        return values
    }

    /// Reads a stored look back over the scene's defaults, clamping as it goes, so a
    /// hand edited plist cannot put a scene somewhere it cannot draw.
    init(stored values: [String: Any], kind: SceneKind) {
        self = Self.defaults(for: kind)
        if let id = values[Key.paletteID] as? String,
           Palette.all.contains(where: { $0.id == id }) {
            paletteID = id
        }
        if let custom = values[Key.isCustom] as? Bool {
            isCustom = custom
        }
        if let value = values[Key.low] as? Int {
            low = RGB(hex: UInt32(truncatingIfNeeded: value) & 0xFFFFFF)
        }
        if let value = values[Key.high] as? Int {
            high = RGB(hex: UInt32(truncatingIfNeeded: value) & 0xFFFFFF)
        }
        let floor = (values[Key.floor] as? Double) ?? self.floor
        let ceiling = (values[Key.ceiling] as? Double) ?? self.ceiling
        let range = GlowbeatSettings.brightnessRange(settingFloor: floor.isFinite ? floor : 0,
                                                     ceiling: ceiling.isFinite ? ceiling : 1)
        self.floor = range.floor
        self.ceiling = range.ceiling
    }

    private static func hex(_ color: RGB) -> Int {
        Int(color.r) << 16 | Int(color.g) << 8 | Int(color.b)
    }
}
