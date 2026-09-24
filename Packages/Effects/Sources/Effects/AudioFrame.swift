import Foundation

/// One analyzed slice of audio.
///
/// `Effects` defines its own frame type so the package depends on nothing. The app
/// converts `AudioTap.AudioFrame` into this type in `App/Model/FrameBridge.swift`.
public struct AudioFrame: Hashable, Sendable {
    /// Seconds on a monotonic clock. Only differences matter.
    public var time: TimeInterval
    /// Overall loudness, 0 through 1.
    public var rms: Float
    public var bands: BandEnergies

    public init(time: TimeInterval, rms: Float, bands: BandEnergies) {
        self.time = time
        self.rms = rms
        self.bands = bands
    }
}

/// A beat detected in one band.
public struct BeatEvent: Hashable, Sendable {
    public var band: Band
    public var time: TimeInterval
    /// The energy that crossed the threshold, 0 through 1.
    public var energy: Float

    public init(band: Band, time: TimeInterval, energy: Float) {
        self.band = band
        self.time = time
        self.energy = energy
    }
}
