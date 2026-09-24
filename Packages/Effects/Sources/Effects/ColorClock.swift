import Foundation

/// When the room's color moves on: the beat moves the brightness, the phrase moves the
/// color.
///
/// Phil's call on 2026-09-23: "Color changes every 4 beats and crossfades; brightness still
/// hits on every beat." Pulse, Spread and Wave used to cut to the next palette color on
/// every low beat, which at a dance track's six beats a second read as a room hopping hue
/// at constant brightness rather than pulsing. This clock is what they share instead: the
/// palette moves on every `beatsPerColor` low beats, never sooner than `minimumHold` after
/// the last change, and the new color fades in over `crossfade` rather than cutting. The
/// effects keep rising on every beat exactly as before; only the hue waits for the phrase.
///
/// It also lays the color out over the bulbs. Normally every bulb wears the room's color.
/// With Confetti on, each bulb gets its own palette color from `ConfettiScatter`, never
/// the same as its neighbors', re-scattered at every change and crossfading bulb by bulb
/// over the same 0.4 s.
struct ColorClock: Hashable, Sendable {

    /// Low beats on each palette color: a bar of four.
    static let beatsPerColor = 4
    /// The least time a color stays up, so a fast track cannot outrun the phrase. At the
    /// dance track's six beats a second, four beats is 0.65 s; this keeps it nearer a
    /// second.
    static let minimumHold: TimeInterval = 0.8
    /// How long the fade from one color to the next takes. Longer than one tick at every
    /// supported update rate, so no single send jumps the whole distance, and shorter than
    /// the hold, so a change never lands in the middle of the previous one's fade.
    static let crossfade: TimeInterval = 0.4

    /// How many times the color has moved on since the clock started or was reset. Read
    /// by the tests and the simulator: it is the one number that says how often the room
    /// changes hue.
    private(set) var changes = 0
    /// The palette position the room is on, or fading to.
    private(set) var index = 0
    /// The position the current fade started from.
    private var previousIndex = 0
    /// Low beats that have landed on the current color, counting the one that brought it
    /// in.
    private var beatsOnColor = 0
    /// When the current color first showed on a beat: the change that brought it in, or
    /// the session's first beat for the opening color. The hold is measured from here.
    private var colorSince: TimeInterval?
    /// When the current fade started, or nil before the first change.
    private var changedAt: TimeInterval?

    /// Whether each bulb gets its own palette color.
    private(set) var isConfetti = false
    /// Each bulb's palette position before and after its current fade, and when that fade
    /// started. Without confetti every entry is the room's.
    private var layoutFrom: [Int] = []
    private var layoutTo: [Int] = []
    private var layoutChangedAt: TimeInterval?
    /// The palette size the layout was drawn for. A shorter palette read through an old
    /// scatter could put two neighbors on the same color, so a change of size lays out
    /// again.
    private var laidOutPaletteSize = 0
    /// Set by a confetti switch, carried out on the next tick that is not in the middle of
    /// a fade, so a switch never cuts a fade short with a jump.
    private var wantsLayout = false
    private var generator: SeededGenerator

    init() {
        generator = SeededGenerator()
    }

    /// A clock whose confetti scatters the same way every run, for tests.
    init(seed: UInt64) {
        generator = SeededGenerator(seed: seed)
    }

    /// Confetti on or off. The room fades apart or back together from the next tick.
    mutating func setConfetti(_ on: Bool) {
        guard on != isConfetti else { return }
        isConfetti = on
        wantsLayout = true
    }

    /// Once per tick, whether or not a beat landed, so the clock's idea of the time moves
    /// with the effect's. Moves the palette on when this is the beat after four on the
    /// current color and the hold has passed, and lays the colors out over `bulbCount`
    /// bulbs.
    mutating func tick(lowBeat: Bool, bulbCount: Int, palette: Palette, time: TimeInterval) {
        let size = palette.colors.count
        let moved = lowBeat && advance(paletteSize: size, time: time)
        let count = max(0, bulbCount)
        if layoutTo.count != count {
            // A bulb that has just arrived has nothing to fade from.
            layoutTo = layout(count: count, palette: palette, previous: nil)
            layoutFrom = layoutTo
            layoutChangedAt = nil
            wantsLayout = false
        } else if moved || size != laidOutPaletteSize || (wantsLayout && !isFading(at: time)) {
            let previous = layoutTo
            layoutFrom = previous
            layoutTo = layout(count: count, palette: palette, previous: previous)
            layoutChangedAt = time
            wantsLayout = false
        }
        laidOutPaletteSize = size
    }

    /// The room's color at `time`: arrived, or part way through its fade.
    func roomBlend(at time: TimeInterval) -> PaletteBlend {
        PaletteBlend(from: previousIndex, to: index, progress: progress(since: changedAt, at: time))
    }

    /// Each bulb's color at `time`, in the order of the last tick's bulbs.
    func blends(at time: TimeInterval) -> [PaletteBlend] {
        let progress = progress(since: layoutChangedAt, at: time)
        return zip(layoutFrom, layoutTo).map { PaletteBlend(from: $0, to: $1, progress: progress) }
    }

    /// Starts the clock over on the palette's first color, with no beats counted. The
    /// confetti switch is the user's and survives: a resume runs this.
    mutating func reset() {
        let keepsConfetti = isConfetti
        let generator = generator
        self = ColorClock()
        self.generator = generator
        isConfetti = keepsConfetti
    }

    /// Counts a low beat and moves the palette on when it is due. True when it moved.
    private mutating func advance(paletteSize size: Int, time: TimeInterval) -> Bool {
        if colorSince == nil { colorSince = time }
        let held = colorSince.map { time - $0 >= Self.minimumHold - Self.timeTolerance } ?? true
        guard beatsOnColor >= Self.beatsPerColor, held, size > 1 else {
            beatsOnColor += 1
            return false
        }
        previousIndex = index % size
        index = (index + 1) % size
        changes += 1
        changedAt = time
        colorSince = time
        beatsOnColor = 1
        return true
    }

    /// Every bulb on the room's color, or a confetti scatter drawn so that neighbors stay
    /// apart through the fade as well as once they arrive.
    private mutating func layout(count: Int, palette: Palette, previous: [Int]?) -> [Int] {
        guard isConfetti else { return Array(repeating: index, count: count) }
        return ConfettiScatter.scatter(count: count, colors: palette.colors,
                                       previous: previous, using: &generator)
    }

    private func isFading(at time: TimeInterval) -> Bool {
        guard let layoutChangedAt else { return false }
        return time - layoutChangedAt < Self.crossfade - Self.timeTolerance
    }

    /// How far a fade that started at `start` has come by `time`, 0 through 1.
    ///
    /// Rounded to a millionth. Tick times are sums and differences of binary fractions of
    /// a second, so a tick exactly halfway through a fade can compute as 0.4999999999999999,
    /// and a channel that should land on 74.5 would round one step the wrong way. Nothing
    /// anyone can see lives below a millionth of a crossfade.
    private func progress(since start: TimeInterval?, at time: TimeInterval) -> Double {
        guard let start else { return 1 }
        let raw = min(1, max(0, (time - start) / Self.crossfade))
        return (raw * 1_000_000).rounded() / 1_000_000
    }

    /// Slack on the hold for the same binary clock reason: 0.8 s after a beat at 0.1 s
    /// can compute as 0.7999999999999999.
    private static let timeTolerance: TimeInterval = 1e-9
}
