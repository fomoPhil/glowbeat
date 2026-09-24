import Foundation

/// Every bulb shares one color whose brightness follows how loud the room is and whose
/// hue drifts slowly through the palette.
///
/// The other three effects all key off beats, which makes them useless for anything
/// without a drum in it. This one ignores beats entirely and reads `frame.rms`, so an
/// ambient track, a film or a conversation still moves the lights. The brightness is
/// smoothed with the user's Snap and Fade, a fast rise and a slower settle, so it
/// breathes rather than flickers, and the color crossfades continuously, about eight seconds per palette color, so the
/// room never sits on one hue for a whole session.
///
/// With Confetti on, each bulb drifts through the palette from its own scattered start,
/// so neighbors are always a whole palette color or more apart. Glow has no beat to move
/// a color clock, so the scatter is laid out once, when the switch is turned on or the
/// room changes size, and the drift does the rest.
public struct GlowEffect: Effect {

    /// Seconds per palette color. The crossfade runs the whole time, so this is also how
    /// long one full step of the drift takes.
    public static let colorDuration: TimeInterval = 8

    public let kind: EffectKind = .glow

    /// The party gate, so the glow starts from black at the level the user chose to
    /// react to rather than from wherever that level happens to sit.
    private var gate: Double = 0
    /// How quickly the brightness rises and falls, from the Snap and Fade sliders.
    public private(set) var timing: EffectTiming = .standard
    private var envelope = LoudnessEnvelope(attack: EffectTiming.standard.attackFloor,
                                            release: EffectTiming.standard.release)
    /// How far through the palette the drift has walked, counted in colors.
    private var phase: Double = 0
    private var lastTime: TimeInterval?
    /// Where each bulb starts in the palette: all at the first color, or a confetti
    /// scatter. Never ticked with a beat, so it only lays out on a switch or a new room
    /// size, and it crossfades a switch the way the beat effects do.
    private var starts = ColorClock()

    public init() {}

    /// The brightness a smoothed level earns above a gate: nothing at the gate, full at
    /// the top. Pure, so the mapping can be read off without driving an effect.
    public static func brightness(level: Double, gate: Double) -> Double {
        let threshold = min(1, max(0, gate))
        let span = 1 - threshold
        guard span > 0 else { return level >= 1 ? 1 : 0 }
        return min(1, max(0, (level - threshold) / span))
    }

    public mutating func setGate(_ gate: Double) {
        self.gate = min(1, max(0, gate))
    }

    /// Snap and Fade retune the follower in place, so a drag mid track does not restart
    /// the glow from black.
    public mutating func setTiming(_ timing: EffectTiming) {
        self.timing = timing
        envelope.setTiming(attack: timing.attackFloor, release: timing.release)
    }

    public mutating func tick(beats: [BeatEvent],
                              frame: AudioFrame,
                              bulbCount: Int,
                              palette: Palette,
                              time: TimeInterval) -> [EffectOutput] {
        // The level and the drift are aged before the bulb count is considered, so ticks
        // with no bulbs selected do not leave a stale glow behind.
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        let level = Double(envelope.update(frame.rms, elapsed: elapsed))
        phase += elapsed / Self.colorDuration

        let count = max(0, bulbCount)
        starts.tick(lowBeat: false, bulbCount: count, palette: palette, time: time)
        guard count > 0 else { return [] }

        let intensity = Self.brightness(level: level, gate: gate)
        return starts.blends(at: time).map { start in
            let color = driftedColor(in: palette, from: start.from)
                .blended(with: driftedColor(in: palette, from: start.to), amount: start.progress)
            return EffectOutput(color: color, intensity: intensity)
        }
    }

    /// The palette color the drift currently sits on for a bulb that started `offset`
    /// colors along, crossfaded into the next one.
    private func driftedColor(in palette: Palette, from offset: Int) -> RGB {
        guard !palette.colors.isEmpty else { return palette.dimBase }
        let count = palette.colors.count
        let walked = (phase + Double(offset)).truncatingRemainder(dividingBy: Double(count))
        let index = Int(walked) % count
        let fraction = walked - walked.rounded(.down)
        return palette.colors[index].blended(with: palette.colors[(index + 1) % count],
                                             amount: fraction)
    }

    public var confetti: Bool { starts.isConfetti }

    public mutating func setConfetti(_ on: Bool) {
        starts.setConfetti(on)
    }

    public mutating func reset() {
        envelope.reset()
        phase = 0
        lastTime = nil
        starts.reset()
    }
}
