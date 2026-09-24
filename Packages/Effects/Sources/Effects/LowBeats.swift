import Foundation

extension Band {
    /// The two bands a kick drum lands in. Pulse and Wave fire on these, and they are
    /// also `SpreadEffect`'s first group, so they are defined once here.
    static let lowBands: [Band] = [.subBass, .bass]

    /// True for sub bass and bass.
    var isLow: Bool { Band.lowBands.contains(self) }
}

extension Collection where Element == BeatEvent {
    /// True when any beat in this tick landed in a low band.
    var containsLowBeat: Bool { contains { $0.band.isLow } }
}
