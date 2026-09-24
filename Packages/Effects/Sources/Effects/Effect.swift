import Foundation

/// The Party Mode effects, as shown in the picker.
public enum EffectKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pulse
    case spread
    case wave
    case glow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pulse: return "Pulse"
        case .spread: return "Spread"
        case .wave: return "Wave"
        case .glow: return "Glow"
        }
    }

    public var summary: String {
        switch self {
        case .pulse: return "Every bulb flashes together on the beat."
        case .spread: return "Each bulb follows the part of the music you give it."
        case .wave: return "Color travels from bulb to bulb."
        case .glow: return "Louder is brighter. Color drifts through the palette."
        }
    }
}

/// Turns beats and band energies into one color and one intensity per bulb.
///
/// The engine calls `tick` ten times per second by default. Effects are value types so
/// they can be tested by feeding a scripted sequence and reading the returned outputs.
///
/// An effect reports the hue it wants and how hard it is hitting. It never dims: the
/// engine maps the intensity through the brightness range the user set, so the same
/// effect reads the same way in a room kept lit and in a room kept dark.
public protocol Effect: Sendable {
    var kind: EffectKind { get }

    /// - Parameters:
    ///   - beats: every beat detected since the previous tick.
    ///   - frame: the most recent analyzed audio frame.
    ///   - bulbCount: how many outputs to return. Returns an empty array for zero.
    ///   - palette: the colors to draw from.
    ///   - time: seconds on a monotonic clock, used for decay.
    /// - Returns: exactly `bulbCount` outputs, in bulb order.
    mutating func tick(beats: [BeatEvent],
                       frame: AudioFrame,
                       bulbCount: Int,
                       palette: Palette,
                       time: TimeInterval) -> [EffectOutput]

    /// Tells a volume driven effect where the party gate sits, so it can start from
    /// black at the level the user chose to react to. Beat driven effects ignore it.
    mutating func setGate(_ gate: Double)

    /// How fast the effect rises on a hit and how slowly it settles. The engine applies
    /// the user's Snap and Fade here so every effect shares one feel.
    mutating func setTiming(_ timing: EffectTiming)

    /// The timing currently in force. Readable so the engine's wiring can be tested:
    /// an effect built mid session has to be handed the user's Snap and Fade, and from
    /// the outside that is otherwise invisible until the room feels wrong.
    var timing: EffectTiming { get }

    /// Confetti: every bulb gets its own color from the palette and never matches its
    /// neighbors. Works with every effect, so it lives on the protocol rather than on one
    /// effect the way Wave's travel speed does. Live: the room fades apart or back
    /// together from the next tick, and a reset keeps it.
    var confetti: Bool { get }
    mutating func setConfetti(_ on: Bool)

    mutating func reset()
}

extension Effect {
    /// Most effects key off beats and have no use for the gate: the engine already
    /// reports an intensity of zero for every bulb below it.
    public mutating func setGate(_ gate: Double) {}

}
