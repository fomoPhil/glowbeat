import Effects
import Foundation

/// Takes the room down to calm over the user's Fade when the music drops below Trigger
/// Level, rather than in one tick.
///
/// Phil's call on 2026-09-23: "Glide down when the music drops below Trigger Level." Party
/// Mode used to paint every bulb calm the moment the gate shut, which dropped a room that
/// was mid hit from Brightest to Darkest in a single send: up to 48 points of brightness at
/// once, on every track the investigation replayed. Now a shut gate puts a ceiling over
/// the room that starts at its brightest bulb and falls at the same rate the effects fall
/// after a hit, so the gate closing looks like the music fading rather than a switch.
///
/// The ceiling is the room's, not each bulb's. The effect is still ticked with no beats
/// while the gate is shut, so its own decay and its own motion carry on underneath: Wave's
/// highlight keeps traveling along the room as it fades, which a cap on each bulb's own
/// history would stop dead, because the bulb it moves onto was dark a tick ago. The
/// ceiling only matters where the effect would hold the room up or raise it, which a
/// volume driven effect or a soft Snap mid rise can. Reopening lifts it at once: a hit
/// after a quiet passage should land.
struct GateGlide {

    /// The most any bulb may show while the gate is shut. Tracks the room's brightest
    /// bulb while the gate is open, and starts at nothing, so a session that begins below
    /// the gate is calm from its first tick.
    private var ceiling: Double = 0
    private var lastTime: TimeInterval?

    /// The outputs to render this tick. Open: exactly what the effect asked for. Shut:
    /// every bulb held at or under a ceiling that falls by `elapsed / release` a tick from
    /// the room's brightest bulb when the gate shut. Colors pass through untouched.
    mutating func apply(_ outputs: [EffectOutput],
                        isOpen: Bool,
                        release: TimeInterval,
                        time: TimeInterval) -> [EffectOutput] {
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        guard !isOpen else {
            ceiling = outputs.map(\.intensity).max() ?? 0
            return outputs
        }
        ceiling = max(0, ceiling - elapsed / max(release, 0.05))
        return outputs.map { EffectOutput(color: $0.color, intensity: min($0.intensity, ceiling)) }
    }
}
