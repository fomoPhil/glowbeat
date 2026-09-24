import Foundation

/// All bulbs share one color. Every low frequency beat is a hit: the intensity ramps up
/// over the user's Snap, then decays back to nothing over their Fade, so the bulbs settle
/// to the darkest end of the user's brightness range.
///
/// The color follows the phrase rather than the beat: the shared `ColorClock` moves the
/// palette on every four low beats and crossfades to the next color. Cutting the hue on
/// every beat made a busy track read as a room hopping color at constant brightness; with
/// the hue held, the hits read as hits.
///
/// With Confetti on, every bulb still flashes on the same beat, each in its own palette
/// color.
public struct PulseEffect: Effect {

    /// How fast the pulse rises and how slowly it falls, from the Snap and Fade sliders.
    public private(set) var timing: EffectTiming = .standard

    public let kind: EffectKind = .pulse

    private var clock = ColorClock()
    private var level: Double = 0
    /// True while the pulse is still climbing toward a full hit. Snap is an attack, not
    /// a brightness: a soft Snap makes the room take longer to reach full, rather than
    /// stopping it partway up.
    private var isRising = false
    private var lastTime: TimeInterval?

    public init() {}

    public mutating func tick(beats: [BeatEvent],
                              frame: AudioFrame,
                              bulbCount: Int,
                              palette: Palette,
                              time: TimeInterval) -> [EffectOutput] {
        // The decay bookkeeping runs before the bulb count is considered, so ticks with
        // no bulbs selected still age the pulse instead of leaving a stale color behind.
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        let isHit = beats.containsLowBeat
        clock.tick(lowBeat: isHit, bulbCount: bulbCount, palette: palette, time: time)
        if isHit {
            isRising = true
        }

        if isRising {
            level = timing.risen(from: level, over: elapsed)
            if level >= 1 { isRising = false }
        } else {
            level = max(0, level - elapsed / timing.release)
        }

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }

        return clock.blends(at: time).map {
            EffectOutput(color: $0.color(in: palette), intensity: level)
        }
    }

    public mutating func setTiming(_ timing: EffectTiming) {
        self.timing = timing
    }

    public var confetti: Bool { clock.isConfetti }

    public mutating func setConfetti(_ on: Bool) {
        clock.setConfetti(on)
    }

    public mutating func reset() {
        clock.reset()
        level = 0
        isRising = false
        lastTime = nil
    }
}
