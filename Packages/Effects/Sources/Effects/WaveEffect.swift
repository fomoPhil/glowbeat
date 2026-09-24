import Foundation

/// Each low frequency beat pushes a highlight into the first bulb, and it travels along the
/// room at the speed the user set with the Travel slider, so the color moves from bulb to
/// bulb.
///
/// The color it pushes is the shared `ColorClock`'s: the palette moves on every four low
/// beats and crossfades, and the first bulb follows that crossfade rather than cutting.
/// Every cell carries the color it was pushed with, so after a change the new color
/// travels into the room as a band behind the old one, with the crossfade drawn out
/// along the bulbs between them.
///
/// Every bulb also carries its own intensity, which ramps up over the user's Snap and
/// then fades to nothing over their Fade. Without that ramp a bulb would hold full
/// intensity for a single 100 ms tick, which is shorter than a Govee bulb's own fade, and
/// the wave would read as a dim smear rather than a moving highlight.
///
/// A bulb the wave has passed keeps the color it was given and only loses its intensity,
/// so the room behind the highlight rests in the palette's hue at the darkest end of the
/// user's range rather than dropping to black.
///
/// With Confetti on, every cell pushed into the first bulb takes a palette color of its
/// own, never the color of the cell behind it. Cells travel together, so two neighbors
/// never match anywhere along the room, and the confetti streams in at the Travel speed.
public struct WaveEffect: Effect {

    /// How fast a cell rises and how slowly it falls, from the Snap and Fade sliders.
    public private(set) var timing: EffectTiming = .standard

    /// How many bulbs the colors travel along in a second, from the Travel slider.
    ///
    /// Travel used to be whatever the engine's update rate happened to be, because the
    /// wave shifted one bulb on every tick. At the shipped ten updates a second that is
    /// exactly this default, so out of the box the wave moves as it always did.
    public private(set) var bulbsPerSecond: Double = WaveEffect.defaultTravelSpeed

    /// One bulb a second is a crawl across the room; fifteen outruns the 10 updates a
    /// second the bulbs accept, which reads as a color that is simply everywhere at once.
    public static let travelRange: ClosedRange<Double> = 1.0...15.0

    /// Ten bulbs a second, one hop per tick at the shipped update rate.
    public static let defaultTravelSpeed: Double = 10

    public let kind: EffectKind = .wave

    /// One bulb's slot in the wave: the color that was pushed in, how bright it is now,
    /// and whether it is still climbing to a full hit. A cell keeps climbing while it
    /// travels, so a soft Snap makes the highlight swell rather than simply dimming it.
    private struct Cell: Hashable, Sendable {
        var color: RGB
        var level: Double
        var isRising: Bool
        /// The palette position a confetti cell was given, which is what the next cell
        /// pushed in front of it has to differ from. Nil for a cell in the clock's color.
        var confettiIndex: Int?
    }

    private var cells: [Cell] = []
    private var clock = ColorClock()
    private var lastTime: TimeInterval?
    public private(set) var confetti = false
    private var generator = SeededGenerator()
    /// Fractions of a hop carried between ticks. Travel is set in bulbs per second and
    /// ticks are whatever the engine's update rate is, so a hop almost never lands on a
    /// tick boundary; without this the wave would round to one hop per tick again and the
    /// slider would do nothing below the update rate.
    private var hopAccumulator: Double = 0

    public init() {}

    /// The travel speed, held inside `travelRange`.
    public static func clampedTravelSpeed(_ bulbsPerSecond: Double) -> Double {
        min(travelRange.upperBound, max(travelRange.lowerBound, bulbsPerSecond))
    }

    public mutating func setTravelSpeed(_ bulbsPerSecond: Double) {
        self.bulbsPerSecond = Self.clampedTravelSpeed(bulbsPerSecond)
    }

    public mutating func tick(beats: [BeatEvent],
                              frame: AudioFrame,
                              bulbCount: Int,
                              palette: Palette,
                              time: TimeInterval) -> [EffectOutput] {
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        let isHit = beats.containsLowBeat
        let count = max(0, bulbCount)
        clock.tick(lowBeat: isHit, bulbCount: count, palette: palette, time: time)
        guard count > 0 else {
            cells = []
            hopAccumulator = 0
            return []
        }

        let color = clock.roomBlend(at: time).color(in: palette)
        if cells.count != count {
            // The bulb count changed, so start the wave over at the new size.
            cells = startingCells(count: count, color: color, palette: palette)
            hopAccumulator = 0
        } else {
            // Rise and fall run on every tick, whether or not the wave hopped: a hit
            // swells and settles over the user's Snap and Fade wherever it is standing.
            let fade = elapsed / timing.release
            for index in cells.indices {
                if cells[index].isRising {
                    cells[index].level = timing.risen(from: cells[index].level, over: elapsed)
                    if cells[index].level >= 1 { cells[index].isRising = false }
                } else {
                    cells[index].level = max(0, cells[index].level - fade)
                }
            }
            advance(by: elapsed, color: color, palette: palette, across: count)
        }

        if isHit {
            // The beat lights the first bulb on the tick it lands rather than waiting for
            // the next hop, so the room reacts on time however slowly the wave travels.
            // At a slow Travel a second beat inside one hop simply takes the first bulb
            // over: there is nowhere else for it to go yet. A confetti cell keeps the
            // color it was pushed with; the beat only lights it.
            let level = timing.risen(from: 0, over: elapsed)
            if !confetti {
                cells[0].color = color
                cells[0].confettiIndex = nil
            }
            cells[0].level = level
            cells[0].isRising = level < 1
        }
        // The first bulb follows the clock for as long as it is first, so a change fades
        // in there even when the next hop is a second away. Once a cell moves on it keeps
        // the color it left with, which is what draws the fade out along the room. A
        // confetti cell left over from before the switch was turned off keeps its color
        // rather than cutting; the next push replaces it.
        if !confetti, cells[0].confettiIndex == nil {
            cells[0].color = color
        }

        return cells.map { EffectOutput(color: $0.color, intensity: $0.level) }
    }

    /// Confetti on or off. Nothing is repainted: the next cells pushed in are confetti,
    /// or the clock's color, and the room turns over at the Travel speed.
    public mutating func setConfetti(_ on: Bool) {
        confetti = on
    }

    /// A fresh room: every cell in the clock's color, or a confetti scatter.
    private mutating func startingCells(count: Int, color: RGB, palette: Palette) -> [Cell] {
        guard confetti, !palette.colors.isEmpty else {
            return Array(repeating: Cell(color: color, level: 0, isRising: false), count: count)
        }
        let layout = ConfettiScatter.scatter(count: count, paletteSize: palette.colors.count,
                                             previous: nil, using: &generator)
        return layout.map {
            Cell(color: palette.colors[$0], level: 0, isRising: false, confettiIndex: $0)
        }
    }

    /// The cell pushed into the first bulb: dark, in the clock's color, or under confetti a
    /// palette color of its own that differs from the cell it lands in front of.
    private mutating func pushedCell(color: RGB, palette: Palette, inFrontOf behind: Cell?) -> Cell {
        let size = palette.colors.count
        guard confetti, size > 0 else {
            return Cell(color: color, level: 0, isRising: false)
        }
        var choices = Array(0..<size)
        if size > 1, let taken = behind?.confettiIndex {
            choices.removeAll { $0 == taken % size }
        }
        let pick = choices.randomElement(using: &generator) ?? 0
        return Cell(color: palette.colors[pick], level: 0, isRising: false, confettiIndex: pick)
    }

    /// Shifts the colors along by however many whole hops `elapsed` has earned, keeping
    /// the leftover fraction for the next tick.
    private mutating func advance(by elapsed: TimeInterval,
                                  color: RGB,
                                  palette: Palette,
                                  across count: Int) {
        guard elapsed > 0 else { return }
        // A gap longer than one sweep of the room has already emptied it, so only the
        // phase within the next hop is carried over: an app that was paused for ten
        // minutes must not come back and spin the wave through thousands of hops.
        let sweep = Double(count)
        let requested = elapsed * bulbsPerSecond
        hopAccumulator += requested.isFinite ? min(requested, sweep) : sweep

        let hops = min(count, Int(hopAccumulator))
        guard hops > 0 else { return }
        hopAccumulator -= Double(hops)
        for _ in 0..<hops {
            cells.insert(pushedCell(color: color, palette: palette, inFrontOf: cells.first), at: 0)
            cells.removeLast()
        }
    }

    public mutating func setTiming(_ timing: EffectTiming) {
        self.timing = timing
    }

    public mutating func reset() {
        cells = []
        clock.reset()
        lastTime = nil
        hopAccumulator = 0
    }
}
