import Foundation

/// Which part of the music one bulb follows.
///
/// The raw values are what the app persists, so they are part of the contract: 0 bass,
/// 1 mid, 2 high. That is also the order the round robin fallback deals in, which is
/// what makes `SpreadGroup(rawValue: index % 3)` the old behavior written down.
public enum SpreadGroup: Int, CaseIterable, Codable, Sendable {
    case bass
    case mid
    case high

    /// What the segment says on the Bulbs row.
    public var displayName: String {
        switch self {
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .high: return "High"
        }
    }

    /// The bands a beat has to land in to light this group. Bass takes the two lowest
    /// bands, mid the two middle ones, high the top one.
    public var bands: [Band] {
        switch self {
        case .bass: return Band.lowBands
        case .mid: return [.lowMid, .mid]
        case .high: return [.highMid]
        }
    }
}

/// Each bulb follows the part of the music the user gave it: bass, mid or high. A beat in
/// a band lights that group's bulbs; quiet bulbs report no intensity and sit at the
/// darkest end of the user's brightness range.
///
/// With no assignment the bulbs are dealt round robin, which is what Spread did before
/// the choice existed, so a room nobody has touched behaves exactly as it always has.
///
/// All three groups draw from the same palette color. Giving each group a color of its
/// own made the room read as three unrelated things happening at once. One hue family,
/// a deeper shade at the bass end and a paler one at the top, reads as one room reacting
/// to one piece of music, which is why only a bass beat moves the shared color clock on
/// and all three groups move with it. That holds however the bulbs are assigned: a room
/// with nothing on Bass still changes hue on the kick.
///
/// Every group reaches full brightness on its beat. Phil's call on 2026-09-23: the bass
/// bulbs used to report 60 percent of a hit, so they never reached the top of the room's
/// range, and he wanted them at full with bass and treble told apart by color alone. So
/// the groups differ only in hue, the way the engine's contract asks: the bass group
/// leans toward a deeper palette color (`bassTone`), the mid group wears the palette
/// color, and the high group leans toward white. None of them scales its color down; an
/// effect that did would be dimming twice, once here and once through the user's Darkest
/// and Brightest range.
public struct SpreadEffect: Effect {

    /// How fast a group rises and how slowly it falls, from the Snap and Fade sliders.
    public private(set) var timing: EffectTiming = .standard

    /// The group of each bulb, by bulb index, as the user set it. Empty means nobody has
    /// chosen, and every bulb takes the round robin fallback.
    ///
    /// Kept exactly as it was handed over rather than padded or trimmed to the room: the
    /// bulb count is only known at tick time, and a room that loses a bulb for a minute
    /// must not lose the choices made for the bulbs behind it.
    public private(set) var assignment: [SpreadGroup] = []

    /// How far the bass group's color leans toward its deeper palette neighbor.
    public static let bassAmount: Double = 0.4
    /// The furthest it may lean to clear `minimumBassStep`. A palette color that would
    /// need more than half a lean to show is too close to be the one leaned toward.
    public static let maximumBassAmount: Double = 0.5
    /// The least the bass tone may differ from the mid group's color, on its most changed
    /// channel. At full brightness for both, color is the only thing telling them apart.
    public static let minimumBassStep: Int = 24
    /// How far round the color wheel a palette color may sit and still count as a deeper
    /// shade of this one rather than a different color. Blending two hues further apart
    /// than this passes through gray: Neon's green leaning toward its red is olive.
    public static let maximumBassHueDistance: Double = 90
    /// How far the high group's color is taken toward white.
    public static let highlightAmount: Double = 0.45
    /// The least the high group may be brighter than the mid group, in Rec. 601 luma.
    /// Blending a already pale palette color 45 percent toward white barely moves it:
    /// Party's yellow gains nine luma that way, and Warm white's palest color gains
    /// nine as well, so the top of the room would read as the same shade as the middle.
    /// Where there is headroom the blend is deepened until it clears this step; where
    /// there is not, the color goes all the way to white.
    public static let minimumHighlightStep: Double = 24

    public let kind: EffectKind = .spread

    private var levels: [Double] = Array(repeating: 0, count: SpreadGroup.allCases.count)
    /// Which groups are still climbing toward a full hit. Snap is an attack, not a
    /// brightness, so a soft Snap makes a group swell rather than stopping it partway.
    private var rising: [Bool] = Array(repeating: false, count: SpreadGroup.allCases.count)
    private var clock = ColorClock()
    private var lastTime: TimeInterval?

    public init() {}

    /// How the bulbs deal themselves out when nobody has chosen: bass, mid, high, and
    /// round again.
    public static func roundRobin(count: Int) -> [SpreadGroup] {
        guard count > 0 else { return [] }
        return (0..<count).map(fallbackGroup(at:))
    }

    /// Sets the group of each bulb, one entry per bulb index, in the room's own order.
    ///
    /// A shorter array is not an error: a bulb discovered since the user last chose has
    /// no entry, and it takes the round robin fallback for its position rather than going
    /// dark. A longer one is simply not all drawn.
    public mutating func setAssignment(_ groups: [SpreadGroup]) {
        assignment = groups
    }

    /// The group bulb `index` follows: the user's choice, or the round robin fallback.
    private func group(at index: Int) -> SpreadGroup {
        guard index >= 0 else { return .bass }
        guard index < assignment.count else { return Self.fallbackGroup(at: index) }
        return assignment[index]
    }

    private static func fallbackGroup(at index: Int) -> SpreadGroup {
        // `allCases` is never empty and the modulo is never negative here, so the
        // fallback in this initializer is unreachable; bass is the safe answer anyway.
        SpreadGroup(rawValue: index % SpreadGroup.allCases.count) ?? .bass
    }

    public mutating func tick(beats: [BeatEvent],
                              frame: AudioFrame,
                              bulbCount: Int,
                              palette: Palette,
                              time: TimeInterval) -> [EffectOutput] {
        let count = max(0, bulbCount)
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        for group in SpreadGroup.allCases {
            let index = group.rawValue
            if beats.contains(where: { group.bands.contains($0.band) }) {
                rising[index] = true
            }
            if rising[index] {
                levels[index] = timing.risen(from: levels[index], over: elapsed)
                if levels[index] >= 1 { rising[index] = false }
            } else {
                levels[index] = max(0, levels[index] - elapsed / timing.release)
            }
        }

        clock.tick(lowBeat: beats.containsLowBeat, bulbCount: count, palette: palette, time: time)

        guard count > 0 else { return [] }
        // With nothing to draw from there is no hue to shade, so shading the dim base
        // would only make the room three slightly wrong shades of off.
        guard !palette.colors.isEmpty else {
            return Array(repeating: EffectOutput(color: palette.dimBase, intensity: 0),
                         count: count)
        }

        // Each bulb's group shades both ends of its crossfade and then mixes them, so a
        // change runs from one shade of the old color to the same shade of the new one.
        // Without confetti every bulb shares the room's color; with it each has its own.
        return clock.blends(at: time).enumerated().map { bulbIndex, blend in
            let group = group(at: bulbIndex)
            let color = blend.color(in: palette) { Self.tone(at: $0, in: palette, forGroup: group) }
            return EffectOutput(color: color, intensity: levels[group.rawValue])
        }
    }

    public var confetti: Bool { clock.isConfetti }

    /// Confetti gives every bulb its own palette color in its group's shade: bass deeper,
    /// high toward white. Two bulbs on one band stop being one color.
    public mutating func setConfetti(_ on: Bool) {
        clock.setConfetti(on)
    }

    /// The hue the given group wears for palette color `index`: a deeper relative of it
    /// at the bass end, the color itself in the middle, a paler relative at the top.
    private static func tone(at index: Int, in palette: Palette, forGroup group: SpreadGroup) -> RGB {
        switch group {
        case .bass: return bassTone(at: index, in: palette)
        case .mid: return palette.colors[index]
        case .high: return highlight(palette.colors[index])
        }
    }

    /// The bass group's color for palette color `index`: the color leaned 40 percent
    /// toward a deeper palette color, or as much further as it takes, up to half way, for
    /// the two to read apart at full brightness.
    ///
    /// Which color it leans toward, in order:
    /// 1. The palette color nearest in hue that is darker and within
    ///    `maximumBassHueDistance`, which is a deeper shade of the same color: Fire's amber
    ///    toward its orange, Blacklight's violets toward its indigo.
    /// 2. The darkest color in its corner of the wheel has nothing darker nearby, so it
    ///    leans toward the palette color nearest in hue instead: a sibling rather than a
    ///    shadow, told apart by hue. Party's red leans toward its orange.
    /// 3. A palette with nothing else in it leans toward the fully saturated version of its
    ///    own hue.
    ///
    /// A color too close to lean toward, one that would need more than `maximumBassAmount`
    /// to clear `minimumBassStep`, is passed over: Blacklight's first two violets are
    /// nearly the same color, so each leans past the other.
    public static func bassTone(at index: Int, in palette: Palette) -> RGB {
        let colors = palette.colors
        guard colors.indices.contains(index) else { return palette.dimBase }
        let color = colors[index]
        let farEnough = Double(minimumBassStep) / maximumBassAmount
        let candidates = colors.indices
            .filter { $0 != index && Double(colors[$0].channelDistance(to: color)) >= farEnough }
            .map { colors[$0] }
        let byHue: (RGB, RGB) -> Bool = { first, second in
            let firstDistance = first.hueDistance(to: color)
            let secondDistance = second.hueDistance(to: color)
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            return first.luminance < second.luminance
        }
        let deeper = candidates.filter {
            $0.luminance < color.luminance && $0.hueDistance(to: color) <= maximumBassHueDistance
        }
        let saturated = Self.saturated(color)
        let target = deeper.min(by: byHue)
            ?? candidates.min(by: byHue)
            ?? (Double(saturated.channelDistance(to: color)) >= farEnough ? saturated : nil)
        guard let target else { return color }
        let amount = max(bassAmount, Double(minimumBassStep) / Double(target.channelDistance(to: color)))
        return color.blended(with: target, amount: amount)
    }

    /// The same hue at the same brightest channel with no white in it: the least channel
    /// taken to zero and the middle one stretched to match. A gray has no hue to saturate.
    private static func saturated(_ color: RGB) -> RGB {
        let channels = [Double(color.r), Double(color.g), Double(color.b)]
        let high = channels.max() ?? 0
        let low = channels.min() ?? 0
        guard high > low else { return color }
        let stretched = channels.map { UInt8(min(255, max(0, ((($0 - low) * high) / (high - low)).rounded()))) }
        return RGB(r: stretched[0], g: stretched[1], b: stretched[2])
    }

    /// Luma is linear in the blend amount, so the amount that buys a given step up is
    /// just the step over the headroom left between this color and white.
    private static func highlight(_ base: RGB) -> RGB {
        let headroom = 255 - base.luminance
        guard headroom > 0 else { return base }
        let needed = minimumHighlightStep / headroom
        return base.blended(with: .white, amount: min(1, max(highlightAmount, needed)))
    }

    public mutating func setTiming(_ timing: EffectTiming) {
        self.timing = timing
    }

    /// Clears what the music did, never what the user chose. A resume runs this, and a
    /// resume that forgot which bulb was on Bass would be a bug nobody could see coming.
    public mutating func reset() {
        levels = Array(repeating: 0, count: SpreadGroup.allCases.count)
        rising = Array(repeating: false, count: SpreadGroup.allCases.count)
        clock.reset()
        lastTime = nil
    }
}
