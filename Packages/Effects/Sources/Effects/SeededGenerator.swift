import Foundation

/// A small, fast, seedable random number generator.
///
/// SplitMix64, which is the generator Swift's own `SystemRandomNumberGenerator` cannot
/// give: a seed. Candle's flicker is a random walk, and a test has to be able to run the
/// same flicker twice. It is a value type, so it is `Sendable` and can live inside a
/// scene without making the scene unsafe to hand between actors.
public struct SeededGenerator: RandomNumberGenerator, Hashable, Sendable {

    private var state: UInt64

    /// A generator that produces the same sequence for the same seed, every run.
    public init(seed: UInt64) {
        self.state = seed
    }

    /// A generator seeded from the system, which is what the app uses: two candles lit
    /// on different evenings should not flicker identically.
    public init() {
        self.init(seed: UInt64.random(in: UInt64.min...UInt64.max))
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
