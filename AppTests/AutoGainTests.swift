import AudioTap
import XCTest
@testable import Glowbeat

/// `AutoGain` is what makes the level meter and the beat detector work at whatever
/// volume the Mac happens to be playing at. These pin the four things that matters:
/// any steady level eventually fills the range, silence stays silent, the floor stops
/// hiss being amplified into music, and a reset starts over.
final class AutoGainTests: XCTestCase {

    private let frameRate: Double = 50

    private func frame(atIndex index: Int, rms: Float, band: Float? = nil) -> AudioTap.AudioFrame {
        let level = band ?? rms
        return AudioTap.AudioFrame(time: Double(index) / frameRate,
                                   rms: rms,
                                   bands: Array(repeating: level, count: 5))
    }

    /// Feeds `count` frames at one steady level and returns the last normalized frame.
    private func run(_ gain: inout AutoGain,
                     level: Float,
                     count: Int,
                     from startIndex: Int = 0) -> AudioTap.AudioFrame {
        var last = gain.normalize(frame(atIndex: startIndex, rms: level))
        for index in 1..<max(1, count) {
            last = gain.normalize(frame(atIndex: startIndex + index, rms: level))
        }
        return last
    }

    func testALoudTrackFillsTheRange() {
        var gain = AutoGain()
        let last = run(&gain, level: 0.9, count: 100)
        XCTAssertEqual(last.rms, 1, accuracy: 0.01)
        for band in last.bands {
            XCTAssertEqual(band, 1, accuracy: 0.01)
        }
    }

    /// The point of the decaying peak: a quiet track played after a loud one is not
    /// stuck at a tenth of the bar for the rest of the session.
    func testAQuietTrackAfterALoudOneAlsoFillsTheRange() {
        var gain = AutoGain()
        let loud = run(&gain, level: 0.9, count: 100)
        XCTAssertEqual(loud.rms, 1, accuracy: 0.01)

        let firstQuiet = gain.normalize(frame(atIndex: 100, rms: 0.05))
        XCTAssertLessThan(firstQuiet.rms, 0.1, "The peak has not decayed yet.")

        let settled = run(&gain, level: 0.05, count: 1200, from: 101)
        XCTAssertEqual(settled.rms, 1, accuracy: 0.02)
        for band in settled.bands {
            XCTAssertEqual(band, 1, accuracy: 0.02)
        }
    }

    func testSilenceStaysAtZero() {
        var gain = AutoGain()
        let last = run(&gain, level: 0, count: 200)
        XCTAssertEqual(last.rms, 0)
        XCTAssertEqual(last.bands, Array(repeating: 0, count: 5))
    }

    /// Room tone sits well under the floor, so the most it can ever be amplified by is
    /// `1 / floor`. Without the floor a hissing room would read as a full scale signal
    /// and every hiss frame would be a beat.
    func testTheFloorStopsHissBeingAmplifiedToFullScale() {
        var gain = AutoGain()
        let hiss = AutoGain.floor / 2
        let last = run(&gain, level: hiss, count: 500)
        XCTAssertEqual(last.rms, 0.5, accuracy: 0.001)
        for band in last.bands {
            XCTAssertEqual(band, 0.5, accuracy: 0.001)
        }
    }

    func testAFrameLouderThanThePeakIsClampedToOne() {
        var gain = AutoGain()
        _ = run(&gain, level: 0.2, count: 50)
        let jump = gain.normalize(frame(atIndex: 50, rms: 1))
        XCTAssertEqual(jump.rms, 1, accuracy: 0.0001)
        for band in jump.bands {
            XCTAssertEqual(band, 1, accuracy: 0.0001)
        }
    }

    /// Bands track their own peaks, so a track with no treble does not push the high
    /// band up just because the bass is loud.
    func testEachBandTracksItsOwnPeak() {
        var gain = AutoGain()
        for index in 0..<100 {
            _ = gain.normalize(AudioTap.AudioFrame(time: Double(index) / frameRate,
                                                   rms: 0.9,
                                                   bands: [0.9, 0.9, 0.9, 0.9, 0.05]))
        }
        let last = gain.normalize(AudioTap.AudioFrame(time: 2,
                                                      rms: 0.9,
                                                      bands: [0.45, 0.9, 0.9, 0.9, 0.05]))
        XCTAssertEqual(last.bands[0], 0.5, accuracy: 0.01)
        XCTAssertEqual(last.bands[1], 1, accuracy: 0.01)
        XCTAssertEqual(last.bands[4], 1, accuracy: 0.01)
    }

    func testResetForgetsThePeaks() {
        var gain = AutoGain()
        _ = run(&gain, level: 0.9, count: 100)
        gain.reset()
        // With the peaks back at the floor, a frame at the floor is full scale again.
        let afterReset = gain.normalize(frame(atIndex: 200, rms: AutoGain.floor))
        XCTAssertEqual(afterReset.rms, 1, accuracy: 0.0001)
        for band in afterReset.bands {
            XCTAssertEqual(band, 1, accuracy: 0.0001)
        }
    }
}
