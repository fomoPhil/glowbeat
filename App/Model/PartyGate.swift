import Effects
import Foundation

/// Decides when the room is loud enough for Party Mode to react.
///
/// Auto-gain fills the level bar at any volume, which is what Phil wanted, but it also
/// means quiet audio can still reach the beat detector as a full scale signal and light
/// the room up. The gate is the user's answer to that: they drag a marker to the level
/// below which Glowbeat should leave the bulbs at the palette's dim base.
///
/// What it actually catches is bounded by how fast auto-gain follows. The tracked peak
/// halves in about four seconds and reaches a tenth in fifteen to twenty, so a long quiet
/// passage is renormalized back to full scale and the gate stops holding it down. The
/// cases this genuinely covers are short gaps between and inside tracks, intros and
/// outros under about fifteen seconds, and true silence, where the RMS is zero and the
/// floor keeps it there however long it lasts.
///
/// Opening is judged on the raw frame rather than on the smoothed level, so a hit that
/// lasts a tenth of a second still lights the room instead of being averaged away. It
/// takes two frames in a row over the marker, 40 ms at the tap's 50 frames a second, so
/// one stray frame, a system alert or a click, cannot flash the whole room. Closing is
/// judged on the smoothed level, with hysteresis, because a raw reading crosses a fixed
/// line several times a second on ordinary music and would chatter the bulbs.
struct PartyGate {

    /// The longest the follower's own rise may be, whatever Snap says: the meter and the
    /// close decision read it, and a slow meter would lag the marker the user is dragging.
    static let attack: TimeInterval = 0.02
    /// The shortest the gate may hold open, whatever Fade says. A floor, not the actual
    /// release: the user's Fade is used when it is longer, which it is by default. Long
    /// enough to ride out the gap between two beats, short enough that a burst does not
    /// hold the room open for long.
    static let release: TimeInterval = 0.3
    /// An open gate closes at this fraction of the level it opened at.
    static let closeRatio: Double = 0.8
    /// How many frames in a row have to clear the marker before the gate opens. Two
    /// frames is 40 ms at the tap's 50 frames a second: fast enough that a real hit is
    /// not missed, long enough that a lone system alert cannot flash the room.
    static let framesToOpen = 2

    /// 0 through 1. A threshold of 0 means the gate is always open.
    var threshold: Double {
        didSet { threshold = min(1, max(0, threshold)) }
    }

    private(set) var isOpen = false

    /// The smoothed level the threshold is compared against, 0 through 1.
    var loudness: Float { envelope.value }

    /// The level an open gate falls back through before it shuts.
    var closeThreshold: Double { threshold * Self.closeRatio }

    private var envelope = LoudnessEnvelope(attack: PartyGate.attack, release: PartyGate.release)
    /// How many frames in a row have cleared the marker, counted only while shut.
    private var framesOverThreshold = 0

    init(threshold: Double, timing: EffectTiming = .standard) {
        self.threshold = min(1, max(0, threshold))
        setTiming(timing)
    }

    /// Snap and Fade. The follower's rise stays quick whatever Snap says, because the
    /// meter and the close decision read it and a slow meter would lag the marker; the
    /// user's Fade is what holds the gate open after a hit.
    mutating func setTiming(_ timing: EffectTiming) {
        envelope.setTiming(attack: min(Self.attack, max(0.005, timing.attack)),
                           release: max(Self.release, timing.release))
    }

    /// Folds one audio frame's auto-gained RMS in and returns whether the gate is open.
    ///
    /// Opening is judged on the raw frames: `framesToOpen` in a row over the marker open
    /// the gate, so a hit that lasts a tenth of a second still lights the room while a
    /// single stray frame does not. Only the close is judged on the smoothed level, which
    /// is what stops the gate chattering shut between two beats.
    @discardableResult
    mutating func update(rms: Float, elapsed: TimeInterval) -> Bool {
        let level = Double(envelope.update(rms, elapsed: elapsed))
        let raw = Double(min(1, max(0, rms)))
        // A marker at the bottom means react to everything, including silence, so there
        // is nothing to wait two frames for.
        guard threshold > 0 else {
            isOpen = true
            return true
        }
        if isOpen {
            if level < closeThreshold && raw < threshold { isOpen = false }
        } else {
            // Only the raw run opens the gate. The smoothed level deliberately gets no
            // say here: one frame at full scale drags it most of the way up in 20 ms, so
            // letting it open the gate would put the stray alert sound straight back.
            framesOverThreshold = raw >= threshold ? framesOverThreshold + 1 : 0
            if framesOverThreshold >= Self.framesToOpen { isOpen = true }
        }
        if isOpen { framesOverThreshold = 0 }
        return isOpen
    }

    mutating func reset() {
        envelope.reset()
        isOpen = false
        framesOverThreshold = 0
    }
}
