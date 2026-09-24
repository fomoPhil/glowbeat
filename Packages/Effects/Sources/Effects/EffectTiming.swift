import Foundation

/// How fast the lights jump on a hit and how slowly they settle afterward, in seconds.
///
/// Phil asked for this the way an audio compressor exposes it: an attack and a release.
/// Two plain sliders drive it, Snap and Fade, each 0 through 1, and this maps them onto
/// time constants every effect and the party gate share, so the whole room has one feel.
public struct EffectTiming: Hashable, Sendable {

    /// Seconds for the intensity to rise on a hit. Zero is instant.
    public let attack: TimeInterval
    /// Seconds for the intensity to fall back to nothing after a hit.
    public let release: TimeInterval

    public init(attack: TimeInterval, release: TimeInterval) {
        self.attack = max(0, attack)
        self.release = max(0.05, release)
    }

    /// Snap 0 takes a quarter second to rise; Snap 1 is instant. The curve is squared so
    /// most of the slider is usefully quick and only the far left feels soft.
    public static let slowestAttack: TimeInterval = 0.25
    /// Fade 0 settles in 150 ms, a tight flicker; Fade 1 takes five seconds, a slow
    /// breath that outlasts several beats.
    public static let fastestRelease: TimeInterval = 0.15
    public static let slowestRelease: TimeInterval = 5.0

    /// The shortest attack anything actually runs at. A ramp this fast completes inside
    /// a single tick at every supported update rate, so Snap at the top still reads as
    /// instant, and nothing has to divide by zero to get there.
    public static let shortestAttack: TimeInterval = 0.01

    /// How close to a full hit counts as arrived. An exponential ramp only approaches its
    /// target, so without this a pulse would sit a hair under the palette color forever
    /// and never quite hand over to the release.
    public static let riseCompleted: Double = 0.99

    /// The attack a Snap value asks for, in seconds.
    public static func attack(forSnap snap: Double) -> TimeInterval {
        let amount = min(1, max(0, snap))
        return slowestAttack * (1 - amount) * (1 - amount)
    }

    /// The release a Fade value asks for, in seconds.
    ///
    /// Releases are perceived on a log scale: halving 5 s feels like the same step as
    /// halving 0.3 s, so the slider interpolates the logarithm.
    public static func release(forFade fade: Double) -> TimeInterval {
        let amount = min(1, max(0, fade))
        let logRelease = log(fastestRelease) + (log(slowestRelease) - log(fastestRelease)) * amount
        return exp(logRelease)
    }

    /// The timing two 0 through 1 slider values ask for.
    public static func from(snap: Double, fade: Double) -> EffectTiming {
        EffectTiming(attack: attack(forSnap: snap), release: release(forFade: fade))
    }

    /// The Snap value that asks for a given attack, the inverse of `attack(forSnap:)`.
    /// Used to state a default as the feel it produces rather than as a bare number.
    public static func snap(forAttack attack: TimeInterval) -> Double {
        let clamped = min(slowestAttack, max(0, attack))
        return min(1, max(0, 1 - (clamped / slowestAttack).squareRoot()))
    }

    /// The Fade value that asks for a given release, the inverse of `release(forFade:)`.
    public static func fade(forRelease release: TimeInterval) -> Double {
        let clamped = min(slowestRelease, max(fastestRelease, release))
        return (log(clamped) - log(fastestRelease)) / (log(slowestRelease) - log(fastestRelease))
    }

    /// The package's own default, worn by an effect built without an engine to hand it
    /// the user's Snap and Fade: a 50 ms rise, which is what Glow shipped with before
    /// Snap existed, and a half second settle, which is what Pulse and Wave shipped with.
    /// Spread and Glow settled in 400 ms and the gate held for 300; both follow this one
    /// value, so every part of the room has the same feel.
    ///
    /// This is no longer what Glowbeat itself starts on. Since 2026-09-14 the app ships
    /// on the Punchy feel, whose numbers live in `PartyPreset`, and the engine hands them
    /// to every effect it builds.
    public static let standard = EffectTiming(attack: 0.05, release: 0.5)

    /// The Snap slider value `standard` asks for, about 0.55.
    public static let standardSnap = snap(forAttack: standard.attack)
    /// The Fade slider value `standard` asks for, about 0.34.
    public static let standardFade = fade(forRelease: standard.release)

    /// The attack actually used by a volume driven effect, never shorter than
    /// `shortestAttack`. Glow follows the music continuously, so it wants the whole
    /// attack: 50 ms at the default is what it shipped with.
    public var attackFloor: TimeInterval { max(Self.shortestAttack, attack) }

    /// How much of the attack a beat driven effect uses.
    ///
    /// One slider has to serve two different things. Glow is following a level, where
    /// 50 ms is a breath; Pulse, Wave and Spread are reacting to an impulse, where the
    /// same 50 ms would put a hit at 86 percent on the first tick and leave the default
    /// noticeably softer than the instant hit these effects shipped with. A fifth of the
    /// attack lands a default hit inside one tick and still leaves the whole left hand
    /// side of the slider ramping visibly, which is what the slider is for.
    public static let beatAttackScale: Double = 0.2

    /// The attack a beat driven effect ramps over.
    public var beatAttack: TimeInterval { max(0.005, attack * Self.beatAttackScale) }

    /// Where a beat driven effect's level sits after ramping toward a full hit for
    /// `elapsed` seconds.
    ///
    /// One pole, like `LoudnessEnvelope`, over `beatAttack`: the level covers 63 percent
    /// of whatever is left in one attack, and arrives, exactly, once it is within
    /// `riseCompleted` of the top. A tick with no time on it has nothing to ramp over,
    /// and a beat that landed on the very first tick of a session would otherwise leave
    /// the room dark until the next one, so that case lands in full.
    public func risen(from level: Double, over elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 1 }
        let next = level + (1 - level) * (1 - exp(-elapsed / beatAttack))
        return next >= Self.riseCompleted ? 1 : next
    }
}
