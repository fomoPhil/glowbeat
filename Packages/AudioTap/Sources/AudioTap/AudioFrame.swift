import Foundation

/// One analyzed slice of the Mac's audio output.
///
/// `AudioTap` defines its own frame type so the package depends on nothing outside
/// CoreAudio and Accelerate. The app converts it to `Effects.AudioFrame` in
/// `App/Model/FrameBridge.swift`.
public struct AudioFrame: Hashable, Sendable {
    /// Seconds on a monotonic clock. Only differences matter.
    public var time: TimeInterval
    /// Overall loudness, 0 through 1.
    public var rms: Float
    /// Exactly five values, 0 through 1: sub bass, bass, low mid, mid, high mid.
    public var bands: [Float]

    public init(time: TimeInterval, rms: Float, bands: [Float]) {
        self.time = time
        self.rms = rms
        var padded = Array(bands.prefix(5))
        while padded.count < 5 {
            padded.append(0)
        }
        self.bands = padded
    }
}
