import Foundation

/// A one pole follower that smooths a 0 through 1 loudness reading.
///
/// Raw RMS jumps around from frame to frame, and anything driven straight off it either
/// flickers or chatters across a threshold. This rises quickly and falls slowly, which is
/// how a level reads to the eye: the party gate uses it to decide when the room is loud
/// enough to react to, and `GlowEffect` uses it to breathe rather than strobe.
///
/// `attack` and `release` are time constants in seconds: one of them covers about 63
/// percent of the remaining distance, three of them effectively arrive.
public struct LoudnessEnvelope: Hashable, Sendable {

    public private(set) var attack: TimeInterval
    public private(set) var release: TimeInterval

    /// The smoothed level, 0 through 1.
    public private(set) var value: Float = 0

    public init(attack: TimeInterval, release: TimeInterval) {
        self.attack = max(0, attack)
        self.release = max(0, release)
    }

    /// Moves the envelope `elapsed` seconds toward `target` and returns the new value.
    /// A non positive `elapsed` leaves it where it is, so a tick with no time on it
    /// cannot move the level.
    @discardableResult
    public mutating func update(_ target: Float, elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return value }
        let goal = min(1, max(0, target))
        let timeConstant = goal > value ? attack : release
        guard timeConstant > 0 else {
            value = goal
            return value
        }
        let remaining = Float(exp(-elapsed / timeConstant))
        value = goal + (value - goal) * remaining
        return value
    }

    /// Retunes the follower without disturbing the level it is holding.
    public mutating func setTiming(attack: TimeInterval, release: TimeInterval) {
        self.attack = max(0, attack)
        self.release = max(0, release)
    }

    public mutating func reset() {
        value = 0
    }
}
