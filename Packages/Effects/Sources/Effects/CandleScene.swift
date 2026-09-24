import Foundation

/// A warm flicker: every bulb walks its own brightness around a 2200 K amber, between 40
/// and 100 percent.
///
/// Each bulb gets its own walk, because a room of candles that all dip at the same moment
/// reads as a power cut. The walk is mean reverting, pulled back toward a resting
/// brightness on every step, because a free random walk spends most of its time pinned
/// against one rail or the other, which looks like a fault rather than like a flame. The
/// step is measured in scene seconds rather than in ticks, so the flicker looks the same
/// whatever rate the engine happens to run at and the speed slider makes the flame livelier
/// by moving its clock faster.
///
/// The generator is injectable so a test can run the same flicker twice; the app seeds one
/// from the system.
public struct CandleScene: LightScene {

    /// 2200 K as RGB. Deep amber, the color of a real flame rather than of a warm bulb.
    public static let flame = RGB(hex: 0xFF9329)

    public static let minimumBrightness: Double = 0.4
    public static let maximumBrightness: Double = 1.0
    /// Where a flame sits when nothing has disturbed it, and what the walk is pulled back
    /// toward.
    public static let restingBrightness: Double = 0.7
    /// How much of the way back to the resting brightness one nominal step travels.
    public static let reversionRate: Double = 0.2
    /// The largest jump one nominal step may make, as a fraction of the whole range.
    /// Small enough that the walk drifts rather than strobes.
    public static let maximumStepFraction: Double = 0.25

    /// The largest jump in brightness one nominal step may make.
    public static var maximumStep: Double {
        (maximumBrightness - minimumBrightness) * maximumStepFraction
    }

    /// How many nominal steps one tick may ever count as. A tick that arrives after a long
    /// stall, a sleep or a stopped debugger, must not teleport the whole room.
    private static let maximumStepsPerTick: Double = 4

    public let kind: SceneKind = .candle

    private var clock = SceneClock()
    private var generator: SeededGenerator
    private var brightnesses: [Double] = []

    /// - Parameter generator: seeded by the system unless a test hands one in.
    public init(generator: SeededGenerator = SeededGenerator()) {
        self.generator = generator
    }

    public mutating func tick(bulbCount: Int,
                              palette: Palette,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        // The clock is advanced before the bulb count is considered, so a tick with no
        // bulbs selected does not save up scene time and spend it all at once later.
        let elapsed = clock.advance(to: time, speed: speed)

        let count = max(0, bulbCount)
        guard count > 0 else {
            brightnesses = []
            return []
        }

        if brightnesses.count != count {
            // A steady start, so lighting the candles is not a flash of full brightness.
            brightnesses = Array(repeating: Self.restingBrightness, count: count)
        }

        // How much of a nominal step this tick is worth. Speed is already in the clock, so
        // at 4x each tick is four steps of flicker and the flame is that much livelier.
        let steps = min(Self.maximumStepsPerTick,
                        elapsed * Double(SceneKind.updatesPerSecond))
        let jumpLimit = Self.maximumStep * steps
        let pull = min(1, Self.reversionRate * steps)

        for index in brightnesses.indices {
            let jump = jumpLimit > 0
                ? Double.random(in: -jumpLimit...jumpLimit, using: &generator)
                : 0
            let reverted = brightnesses[index]
                + (Self.restingBrightness - brightnesses[index]) * pull
            brightnesses[index] = min(Self.maximumBrightness,
                                      max(Self.minimumBrightness, reverted + jump))
        }

        return brightnesses.map { Self.flame.scaled(by: $0) }
    }

    public mutating func reset() {
        clock.reset()
        brightnesses = []
    }
}
