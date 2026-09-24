import Foundation

/// Every bulb brightens and dims together between the palette's dim base and one palette
/// color: one full breath every six seconds at 1x, and the next palette color each time
/// the breath comes back around.
///
/// It starts at the top and breathes out first. Switching the scene on usually happens in
/// a room whose bulbs are already lit, so opening with a dim reads as the scene taking
/// over what is already there; opening from the dim base would drop the room to almost
/// nothing first, which reads as the lights going out.
///
/// A cosine rather than a triangle. A linear ramp turns around sharply at the top and the
/// bottom, which reads as a light being switched rather than as breathing.
public struct BreatheScene: LightScene {

    /// Seconds for one full breath, in and out, at 1x.
    public static let breathDuration: TimeInterval = 6

    public let kind: SceneKind = .breathe

    private var clock = SceneClock()
    private var cursor = PaletteCursor()
    /// Which breath the scene is on, so the palette advances once per breath rather than
    /// once per tick that happens to land near the bottom.
    private var breathsTaken = 0

    public init() {}

    public mutating func tick(bulbCount: Int,
                              palette: Palette,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        _ = clock.advance(to: time, speed: speed)
        let phase = clock.elapsed / Self.breathDuration

        let breath = Int(phase)
        while breathsTaken <= breath {
            cursor.advance(in: palette)
            breathsTaken += 1
        }

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }

        // Starts at the palette color and breathes out, so switching the scene on in a lit
        // room is a dim rather than a drop.
        let amount = (1 + cos(phase * 2 * .pi)) / 2
        let color = palette.dimBase.blended(with: cursor.color(in: palette), amount: amount)
        return Array(repeating: color, count: count)
    }

    public mutating func reset() {
        clock.reset()
        cursor.reset()
        breathsTaken = 0
    }
}
