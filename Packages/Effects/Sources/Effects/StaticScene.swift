import Foundation

/// The palette laid across the bulbs in list order and left there: bulb `i` wears color
/// `i` modulo the palette's size. Nothing moves, so after the first send the deduper has
/// nothing left to say and the scene costs no traffic at all.
///
/// In single color mode every bulb wears the palette's first color instead, which is how
/// someone picks one color for the whole room without needing a palette that has only one
/// color in it.
///
/// A palette holds at the style's brightest. Custom colors alternate the high point and
/// the low point along the bulbs, or put the high point on every bulb in single color
/// mode.
public struct StaticScene: LightScene {

    public let kind: SceneKind = .fixed

    /// When true, every bulb wears color 0 rather than its own place in the palette.
    public var singleColor: Bool

    public init(singleColor: Bool = false) {
        self.singleColor = singleColor
    }

    public mutating func tick(bulbCount: Int,
                              style: SceneStyle,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        let count = max(0, bulbCount)
        guard count > 0 else { return [] }
        guard let palette = style.palette else {
            return (0..<count).map { index in
                style.color(at: singleColor || index.isMultiple(of: 2) ? 1 : 0,
                            paletteColor: .black)
            }
        }
        guard !palette.colors.isEmpty else {
            return Array(repeating: palette.dimBase, count: count)
        }
        guard !singleColor else {
            return Array(repeating: style.color(at: 1, paletteColor: palette.colors[0]),
                         count: count)
        }
        return (0..<count).map {
            style.color(at: 1, paletteColor: palette.colors[$0 % palette.colors.count])
        }
    }

    public mutating func reset() {}
}
