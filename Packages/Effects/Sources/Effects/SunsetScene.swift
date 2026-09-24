import Foundation

/// Twenty minutes at 1x from a bright warm white down through deep orange, ending with
/// the bulbs off.
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
                              palette: Palette,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        _ = clock.advance(to: time, speed: speed)

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }

        let walked = progress ?? 0
        let color = Self.warmWhite.blended(with: Self.deepOrange, amount: walked)
        let brightness = 1 - (1 - Self.finalBrightness) * walked
        return Array(repeating: color.scaled(by: brightness), count: count)
    }

    public mutating func reset() {
        clock.reset()
    }
}
