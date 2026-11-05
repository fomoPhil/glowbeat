import Foundation

/// Twenty minutes at 1x from the style's high point down to its low point, ending with
/// the bulbs off. Ships as a bright warm white down through deep orange. With a palette,
/// the color walks the palette from its first color to its last.
///
/// The one scene with an end. `progress` drives the bar in the Scenes section, and
/// `isFinished` is what tells the engine to switch the bulbs off and put the control back
/// to off rather than holding the last color forever.
public struct SunsetScene: LightScene {

    /// The whole timeline at 1x. Four times speed makes it five minutes, quarter speed
    /// makes it eighty.
    public static let duration: TimeInterval = 20 * 60

    /// 4000 K, where it starts.
    public static let warmWhite = RGB(hex: 0xFFD1A3)
    /// 2700 K, where it ends before going out.
    public static let deepOrange = RGB(hex: 0xFFA957)
    /// The brightness it fades to before the bulbs go off.
    public static let finalBrightness: Double = 0.3

    public let kind: SceneKind = .sunset

    private var clock = SceneClock()

    public init() {}

    public var progress: Double? {
        min(1, max(0, clock.elapsed / Self.duration))
    }

    public var isFinished: Bool {
        clock.elapsed >= Self.duration
    }

    public mutating func tick(bulbCount: Int,
                              style: SceneStyle,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        _ = clock.advance(to: time, speed: speed)

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }

        let walked = progress ?? 0
        let color = style.color(at: 1 - walked, paletteColor: paletteColor(walked, style))
        return Array(repeating: color, count: count)
    }

    /// The palette from its first color to its last, `walked` of the way along.
    private func paletteColor(_ walked: Double, _ style: SceneStyle) -> RGB {
        guard let colors = style.palette?.colors, !colors.isEmpty else {
            return style.fallbackColor
        }
        let position = walked * Double(colors.count - 1)
        let index = min(colors.count - 1, Int(position))
        let next = min(colors.count - 1, index + 1)
        return colors[index].blended(with: colors[next], amount: position - Double(index))
    }

    public mutating func reset() {
        clock.reset()
    }
}
