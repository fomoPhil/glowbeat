import AudioTap
import Effects
import Foundation
import GoveeLAN

/// The only place the three packages meet.
///
/// `AudioTap` and `Effects` each define their own `AudioFrame`, and `GoveeLAN` and
/// `Effects` each define their own color type, because the spec requires the packages to
/// know nothing about each other. Conversion lives here and nowhere else.
enum FrameBridge {

    static func effectsFrame(from frame: AudioTap.AudioFrame) -> Effects.AudioFrame {
        Effects.AudioFrame(time: frame.time,
                           rms: frame.rms,
                           bands: Effects.BandEnergies(frame.bands))
    }

    static func goveeColor(from color: Effects.RGB) -> GoveeLAN.GoveeRGB {
        GoveeLAN.GoveeRGB(r: color.r, g: color.g, b: color.b)
    }

    static func effectsColor(from color: GoveeLAN.GoveeRGB) -> Effects.RGB {
        Effects.RGB(r: color.r, g: color.g, b: color.b)
    }
}
