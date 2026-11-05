import Foundation

/// What a scene paints with: its colors, and the two brightnesses it moves between.
///
/// Every scene works out a level for each bulb, 0 at its low point and 1 at its high
/// point: the bottom and top of a breath, a candle's dimmest and brightest flicker, the
/// end and start of a sunset. The style turns that level into a color. Brightness runs
/// from `floor` to `ceiling` with it, and with custom colors so does the color, from
/// `low` to `high`. With a palette the scene picks the palette color itself.
public struct SceneStyle: Hashable, Sendable {

    public enum Colors: Hashable, Sendable {
        case palette(Palette)
        case custom(low: RGB, high: RGB)
    }

    public var colors: Colors
    /// 0 through 1. The brightness at the low point.
    public private(set) var floor: Double
    /// 0 through 1. The brightness at the high point, never below the floor.
    public private(set) var ceiling: Double

    public init(colors: Colors, floor: Double, ceiling: Double) {
        self.colors = colors
        let low = min(1, max(0, floor.isFinite ? floor : 0))
        let high = min(1, max(0, ceiling.isFinite ? ceiling : 1))
        self.floor = min(low, high)
        self.ceiling = max(low, high)
    }

    /// The palette, or nil for custom colors.
    public var palette: Palette? {
        if case .palette(let palette) = colors { return palette }
        return nil
    }

    public var isCustom: Bool {
        palette == nil
    }

    /// How bright `level` is, between the floor and the ceiling.
    public func brightness(at level: Double) -> Double {
        let held = min(1, max(0, level))
        return floor + (ceiling - floor) * held
    }

    /// The color at `level`. `paletteColor` is the color the scene chose from the
    /// palette, and is only used when the style has one.
    public func color(at level: Double, paletteColor: RGB) -> RGB {
        let base: RGB
        switch colors {
        case .palette:
            base = paletteColor
        case .custom(let low, let high):
            base = low.blended(with: high, amount: level)
        }
        return base.scaled(by: brightness(at: level))
    }

    /// What a palette with nothing in it falls back on, so no scene has to guard twice.
    var fallbackColor: RGB {
        switch colors {
        case .palette(let palette): return palette.dimBase
        case .custom(_, let high): return high
        }
    }
}

extension SceneKind {

    /// How the scene looks before anyone has changed it.
    ///
    /// Candle and Sunset ship as custom colors because each one is a look of its own: a
    /// flame and a warm white going down to orange. Written so the shipped numbers give
    /// exactly what those two scenes did before they had a style. The other three take
    /// the palette they are given.
    public func defaultStyle(palette: Palette) -> SceneStyle {
        switch self {
        case .breathe:
            return SceneStyle(colors: .palette(palette), floor: 0.1, ceiling: 1)
        case .colorFlow, .fixed:
            return SceneStyle(colors: .palette(palette), floor: 0.3, ceiling: 1)
        case .candle:
            return SceneStyle(colors: .custom(low: CandleScene.flame, high: CandleScene.flame),
                              floor: 0.4,
                              ceiling: 1)
        case .sunset:
            return SceneStyle(colors: .custom(low: SunsetScene.deepOrange,
                                              high: SunsetScene.warmWhite),
                              floor: SunsetScene.finalBrightness,
                              ceiling: 1)
        }
    }
}
