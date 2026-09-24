import Foundation

/// One bulb's share of a tick: the color the effect wants there, and how hard the effect
/// is hitting right now.
///
/// Effects deliberately do not decide how bright a bulb ends up. They report a hue at
/// full strength and an intensity from 0, calm, to 1, a hit, and the engine maps that
/// intensity through the brightness range the user set with the Darkest and Brightest
/// sliders. Colors are hues; intensity carries brightness. That split is what lets
/// someone keep a room lit at 30 percent and still see every beat, which blending toward
/// a fixed dim color could never do.
public struct EffectOutput: Hashable, Sendable {

    /// The hue for this bulb, at full strength.
    ///
    /// A color, never a brightness. An effect may light or darken a hue by moving it
    /// toward white or toward another color, because that is a different color, but it
    /// must never scale one down to mean "less of this": that is the intensity's job, and
    /// an effect doing both would dim twice, once itself and once through the user's
    /// Darkest and Brightest range.
    public var color: RGB
    /// 0 through 1. Clamped on the way in, so an effect cannot overdrive a bulb.
    public var intensity: Double

    public init(color: RGB, intensity: Double) {
        self.color = color
        self.intensity = min(1, max(0, intensity))
    }

    /// The color to send, with the intensity mapped into the user's range: `floor` at
    /// calm, `ceiling` at a hit. A `ceiling` below the `floor` is treated as the floor,
    /// so a bad pair dims rather than inverts.
    public func rendered(floor: Double, ceiling: Double) -> RGB {
        let low = min(1, max(0, floor))
        let high = max(low, min(1, max(0, ceiling)))
        return color.scaled(by: low + (high - low) * intensity)
    }

    /// The same output with nothing happening, which is what every bulb gets while the
    /// room is below the party gate.
    public var calm: EffectOutput {
        EffectOutput(color: color, intensity: 0)
    }
}
