import Foundation

/// The palette laid across the bulbs in list order and left there: bulb `i` wears color
/// `i` modulo the palette's size. Nothing moves, so after the first send the deduper has
/// nothing left to say and the scene costs no traffic at all.
///
/// In single color mode every bulb wears the palette's first color instead, which is how
/// someone picks one color for the whole room without needing a palette that has only one
/// color in it.
public struct StaticScene: LightScene {

    public let kind: SceneKind = .fixed

    /// When true, every bulb wears color 0 rather than its own place in the palette.
    public var singleColor: Bool

    public init(singleColor: Bool = false) {
        self.singleColor = singleColor
    }

    public mutating func tick(bulbCount: Int,
                              palette: Palette,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        let count = max(0, bulbCount)
        guard count > 0 else { return [] }
        guard !palette.colors.isEmpty else {
            return Array(repeating: palette.dimBase, count: count)
        }
        guard !singleColor else {
            return Array(repeating: palette.colors[0], count: count)
        }
        return (0..<count).map { palette.colors[$0 % palette.colors.count] }
    }

    public mutating func reset() {}
}
