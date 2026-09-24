import Effects
import Foundation

/// A ready made feel for Party Mode: the four values behind the Advanced disclosure,
/// under one name.
///
/// Phil asked for "simple presets that basically change the advanced settings. Like
/// something for fast and bright, low and slow". So that is all a preset is. Trigger
/// Level, Always react, Travel, the effect and the palette are left alone, because those
/// are set for the room and the track rather than for a feel, and a preset that quietly
/// moved them would undo the one thing the user had just dialed in.
///
/// The Snap and Fade values are stated as the times they ask for and converted through
/// `EffectTiming`, so the numbers the readouts print are the numbers written down here
/// rather than slider positions nobody can picture.
enum PartyPreset: String, CaseIterable, Identifiable, Sendable {
    case punchy
    case mellow
    case dreamy
    case tight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .punchy: "Punchy"
        case .mellow: "Mellow"
        case .dreamy: "Dreamy"
        case .tight: "Tight"
        }
    }

    /// One line, in the words someone would use for the room rather than for the
    /// sliders. Shown under the picker for whichever feel is chosen.
    var summary: String {
        switch self {
        case .punchy: "Fast and bright."
        case .mellow: "Low and slow."
        case .dreamy: "Soft hits, long settle."
        case .tight: "Sharp flicker, goes dark between hits."
        }
    }

    /// How dark a bulb sits between hits, the Darkest slider.
    var floor: Double {
        switch self {
        case .punchy: 0.10
        case .mellow: 0.35
        case .dreamy: 0.20
        case .tight: 0.00
        }
    }

    /// How bright a bulb goes on a full hit, the Brightest slider.
    var ceiling: Double {
        switch self {
        case .punchy: 1.00
        case .mellow: 0.80
        case .dreamy: 0.70
        case .tight: 1.00
        }
    }

    /// How fast the lights jump on a hit, as the attack it asks for in seconds. Anything
    /// at or under `EffectTiming.shortestAttack` reads as "instant" on the slider.
    var attack: TimeInterval {
        switch self {
        case .punchy: 0
        case .mellow: 0.06
        case .dreamy: EffectTiming.slowestAttack
        case .tight: 0
        }
    }

    /// How slowly the lights settle after a hit, as the release it asks for in seconds.
    var release: TimeInterval {
        switch self {
        case .punchy: 0.3
        case .mellow: 1.5
        case .dreamy: 3.0
        case .tight: EffectTiming.fastestRelease
        }
    }

    /// The Snap slider position this feel sits at.
    var snap: Double { EffectTiming.snap(forAttack: attack) }

    /// The Fade slider position this feel sits at.
    var fade: Double { EffectTiming.fade(forRelease: release) }

    /// How far a value may sit from a preset's own and still count as that preset.
    ///
    /// Small enough that a deliberate drag lands on Custom, wide enough that the round
    /// trip through `EffectTiming` and back, and a stored value read from disk, still
    /// find the preset they were saved at.
    static let tolerance: Double = 0.005

    /// Whether these four values are this feel.
    func matches(floor: Double, ceiling: Double, snap: Double, fade: Double) -> Bool {
        abs(floor - self.floor) <= Self.tolerance
            && abs(ceiling - self.ceiling) <= Self.tolerance
            && abs(snap - self.snap) <= Self.tolerance
            && abs(fade - self.fade) <= Self.tolerance
    }
}
