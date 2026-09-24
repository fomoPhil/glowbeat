import Foundation
@testable import Effects

extension Effect {

    /// One tick, rendered the way the effects themselves used to render: the palette's
    /// dim base blended toward the color by the intensity.
    ///
    /// The tests that describe an effect's shape, which bulb is brightest, how a pulse
    /// decays, where a wave has traveled to, are about the intensities and the hues, not
    /// about how the engine turns those into a brightness. This keeps them reading in one
    /// color per bulb while `tick` reports color and intensity separately.
    mutating func tickColors(beats: [BeatEvent],
                             frame: AudioFrame,
                             bulbCount: Int,
                             palette: Palette,
                             time: TimeInterval) -> [RGB] {
        tick(beats: beats,
             frame: frame,
             bulbCount: bulbCount,
             palette: palette,
             time: time)
            .map { palette.dimBase.blended(with: $0.color, amount: $0.intensity) }
    }

    /// One tick, reported as intensities alone.
    mutating func tickIntensities(beats: [BeatEvent],
                                  frame: AudioFrame,
                                  bulbCount: Int,
                                  palette: Palette,
                                  time: TimeInterval) -> [Double] {
        tick(beats: beats,
             frame: frame,
             bulbCount: bulbCount,
             palette: palette,
             time: time)
            .map(\.intensity)
    }
}
