import Foundation

extension EffectKind {
    /// Builds a fresh effect of this kind. The engine calls this when the user changes
    /// the picker so no state carries over between effects.
    public func makeEffect() -> any Effect {
        switch self {
        case .pulse: return PulseEffect()
        case .spread: return SpreadEffect()
        case .wave: return WaveEffect()
        case .glow: return GlowEffect()
        }
    }
}
