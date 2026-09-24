import AudioTap
import Foundation

/// Adapts the audio frames to however loud the music actually is.
///
/// The band mapper reports energies on an absolute 0 to 1 scale, and a Mac playing music at
/// a comfortable volume sits around 0.02 to 0.2 on it. The beat detector and the level meter
/// were tuned for a full scale signal, so at normal volume the meter barely moved and only
/// the biggest kicks registered. This tracks a slowly decaying peak per band (and for RMS)
/// and rescales each frame against it, so a quiet track and a loud one both fill the range.
struct AutoGain {

    /// Fraction of the tracked peak kept per frame at 50 frames per second. 0.9965 halves
    /// the peak in about four seconds, so a quiet passage after a loud one recovers quickly
    /// without the gain pumping on every bar.
    static let decayPerFrame: Float = 0.9965

    /// Peaks never fall below this, so silence and hiss are not amplified into beats.
    static let floor: Float = 0.01

    private var rmsPeak: Float = AutoGain.floor
    private var bandPeaks: [Float] = Array(repeating: AutoGain.floor, count: 5)

    mutating func normalize(_ frame: AudioTap.AudioFrame) -> AudioTap.AudioFrame {
        rmsPeak = max(frame.rms, max(Self.floor, rmsPeak * Self.decayPerFrame))
        var bands = frame.bands
        for index in bands.indices where index < bandPeaks.count {
            bandPeaks[index] = max(bands[index], max(Self.floor, bandPeaks[index] * Self.decayPerFrame))
            bands[index] = min(1, bands[index] / bandPeaks[index])
        }
        return AudioTap.AudioFrame(time: frame.time,
                                   rms: min(1, frame.rms / rmsPeak),
                                   bands: bands)
    }

    mutating func reset() {
        rmsPeak = Self.floor
        bandPeaks = Array(repeating: Self.floor, count: 5)
    }
}
