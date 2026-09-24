import XCTest
@testable import Effects

final class BeatDetectorTests: XCTestCase {

    private let frameRate: Double = 50

    private func frame(atIndex index: Int, bass: Float, others: Float = 0) -> AudioFrame {
        AudioFrame(time: Double(index) / frameRate,
                   rms: max(bass, others),
                   bands: BandEnergies([others, bass, others, others, others]))
    }

    /// 250 frames at 50 fps. The bass band sits at 0.1 and bursts to 0.9 for two frames
    /// every 25 frames (every 0.5 s), starting at frame 25.
    private func metronomeFrames() -> [AudioFrame] {
        (0..<250).map { index -> AudioFrame in
            let isBurst = index >= 25 && index % 25 <= 1
            return frame(atIndex: index, bass: isBurst ? 0.9 : 0.1, others: 0.05)
        }
    }

    func testSilenceNeverProducesABeat() {
        var detector = BeatDetector(sensitivity: 1.0)
        var beats: [BeatEvent] = []
        for index in 0..<200 {
            beats += detector.process(frame(atIndex: index, bass: 0))
        }
        XCTAssertTrue(beats.isEmpty)
    }

    func testASteadyToneProducesNoBeatsOnceTheWindowIsFull() {
        var detector = BeatDetector(sensitivity: 0.5)
        var beats: [BeatEvent] = []
        for index in 0..<200 {
            beats += detector.process(frame(atIndex: index, bass: 0.5, others: 0.5))
        }
        XCTAssertTrue(beats.isEmpty)
    }

    func testNoBeatsFireBeforeTheTwentyFrameWindowIsFull() {
        var detector = BeatDetector(sensitivity: 0.5)
        var beats: [BeatEvent] = []
        for index in 0..<BeatDetector.historyEnergyCount {
            beats += detector.process(frame(atIndex: index, bass: index == 10 ? 1.0 : 0.05))
        }
        XCTAssertTrue(beats.isEmpty)
    }

    func testTheMetronomeProducesExactlyOneBassBeatPerBurst() {
        var detector = BeatDetector(sensitivity: 0.5)
        var bassBeats: [BeatEvent] = []
        for audioFrame in metronomeFrames() {
            bassBeats += detector.process(audioFrame).filter { $0.band == .bass }
        }
        // Bursts start at frames 25, 50, 75, ... 225: nine bursts.
        XCTAssertEqual(bassBeats.count, 9)
        let expectedTimes = stride(from: 25, through: 225, by: 25).map { Double($0) / frameRate }
        for (beat, expected) in zip(bassBeats, expectedTimes) {
            XCTAssertEqual(beat.time, expected, accuracy: 0.001)
        }
    }

    func testTheDebounceSuppressesASecondBeatInsideOneTenthOfASecond() {
        var detector = BeatDetector(sensitivity: 1.0)
        var beats: [BeatEvent] = []
        for index in 0..<40 {
            // Quiet for the first 20 frames, then loud for five consecutive frames.
            let isLoud = (20...24).contains(index)
            beats += detector.process(frame(atIndex: index, bass: isLoud ? 0.9 : 0.05))
        }
        let bassBeats = beats.filter { $0.band == .bass }
        // Five consecutive loud frames span 0.08 s, inside the 0.1 s debounce.
        XCTAssertEqual(bassBeats.count, 1)
        XCTAssertEqual(bassBeats[0].time, 0.4, accuracy: 0.001)
    }

    /// The straight line the slider runs along, end to end. Both ends sit inside the
    /// window real music lives in: 1.65 times the rolling mean is as strict as a dense
    /// mix can stand, 1.2 times it is as loose as a dance track can stand.
    func testTheSensitivitySliderHitsItsThreeTunedPoints() {
        XCTAssertEqual(BeatDetector.thresholdMultiplier(forSensitivity: 0), 1.65, accuracy: 0.0001)
        XCTAssertEqual(BeatDetector.thresholdMultiplier(forSensitivity: 0.5), 1.425, accuracy: 0.0001)
        XCTAssertEqual(BeatDetector.thresholdMultiplier(forSensitivity: 1), 1.2, accuracy: 0.0001)
        // Out of range values are clamped rather than extrapolated into nonsense.
        XCTAssertEqual(BeatDetector.thresholdMultiplier(forSensitivity: -4), 1.65, accuracy: 0.0001)
        XCTAssertEqual(BeatDetector.thresholdMultiplier(forSensitivity: 9), 1.2, accuracy: 0.0001)
    }

    /// Turning the slider up must only ever make beats easier. A curve that dipped back
    /// up anywhere would make the control feel broken.
    func testTheThresholdFallsAllTheWayAlongTheSlider() {
        var previous = Float.greatestFiniteMagnitude
        for step in 0...100 {
            let multiplier = BeatDetector.thresholdMultiplier(forSensitivity: Double(step) / 100)
            XCTAssertLessThan(multiplier, previous, "The threshold rose at \(step) percent.")
            previous = multiplier
        }
    }

    /// The endpoints, through the detector rather than the formula. Both ends now sit
    /// inside the window real music lives in, so the bottom is strict rather than deaf
    /// and the top is loose rather than constantly on.
    func testTheSliderEndpointsReachFromOnlyHugeDropsToNearlyEverything() {
        func beatCount(sensitivity: Double, burst: Float, quiet: Float) -> Int {
            var detector = BeatDetector(sensitivity: sensitivity)
            var count = 0
            for index in 0..<250 {
                let isBurst = index >= 25 && index % 25 <= 1
                let audioFrame = frame(atIndex: index, bass: isBurst ? burst : quiet)
                count += detector.process(audioFrame).filter { $0.band == .bass }.count
            }
            return count
        }
        XCTAssertEqual(beatCount(sensitivity: 0, burst: 0.18, quiet: 0.12), 0,
                       "At the bottom of the slider a burst at 1.5 times the mean is not a hit.")
        XCTAssertGreaterThan(beatCount(sensitivity: 0, burst: 0.24, quiet: 0.12), 0,
                             "At the bottom of the slider a burst at twice the mean is a hit.")
        XCTAssertGreaterThan(beatCount(sensitivity: 1, burst: 0.156, quiet: 0.12), 0,
                             "At the top of the slider a burst at 1.3 times the mean is a hit.")
        XCTAssertEqual(beatCount(sensitivity: 1, burst: 0.138, quiet: 0.12), 0,
                       "Even at the top a swell of 15 percent over the mean is not a hit.")
        XCTAssertGreaterThan(beatCount(sensitivity: 0, burst: 0.9, quiet: 0.1), 0,
                             "A real kick still fires at the bottom of the slider.")
    }

    /// A burst at about 1.4 times the rolling mean straddles the slider: it is under the
    /// bottom end's 1.65 and over the top end's 1.2.
    func testHigherSensitivityFiresOnASmallerBurst() {
        func beatCount(sensitivity: Double) -> Int {
            var detector = BeatDetector(sensitivity: sensitivity)
            var count = 0
            for index in 0..<250 {
                let isBurst = index >= 25 && index % 25 <= 1
                let audioFrame = frame(atIndex: index, bass: isBurst ? 0.17 : 0.12)
                count += detector.process(audioFrame).filter { $0.band == .bass }.count
            }
            return count
        }
        XCTAssertGreaterThan(beatCount(sensitivity: 1.0), beatCount(sensitivity: 0.0))
        XCTAssertEqual(beatCount(sensitivity: 0.0), 0)
    }

    func testBeatsAreReportedPerBandIndependently() {
        var detector = BeatDetector(sensitivity: 0.5)
        var beats: [BeatEvent] = []
        for index in 0..<60 {
            let isBurst = index == 30
            let bands = BandEnergies([0.05,
                                      isBurst ? 0.9 : 0.05,
                                      0.05,
                                      0.05,
                                      isBurst ? 0.8 : 0.05])
            beats += detector.process(AudioFrame(time: Double(index) / frameRate,
                                                 rms: 0.5,
                                                 bands: bands))
        }
        XCTAssertEqual(Set(beats.map(\.band)), [.bass, .highMid])
        XCTAssertEqual(beats.count, 2)
    }

    func testResetClearsTheWindow() {
        var detector = BeatDetector(sensitivity: 0.5)
        for index in 0..<30 {
            _ = detector.process(frame(atIndex: index, bass: 0.05))
        }
        detector.reset()
        var beats: [BeatEvent] = []
        for index in 30..<40 {
            beats += detector.process(frame(atIndex: index, bass: 0.9))
        }
        XCTAssertTrue(beats.isEmpty, "After a reset the window must refill before beats fire.")
    }

    // MARK: Real music, not metronomes

    /// A dense mix keeps the bass band busy between kicks, so a kick sits only around
    /// 1.5 to 1.6 times the rolling mean. Replaying real tracks through the pipeline
    /// (2026-09-14) showed a hip hop mix at Phil's marker position firing one bass beat
    /// every nine seconds, because the top half of the marker asked for 1.9 to 2.5 times
    /// the mean and nothing in the mix ever cleared it. A sensitivity of 0.3 is what a
    /// marker at 70 percent derives, and a kick at 1.6 times the mean has to count there.
    func testAKickAtOnePointSixTimesTheMeanCountsWithTheMarkerHigh() {
        var detector = BeatDetector(sensitivity: 0.3)
        var beats: [BeatEvent] = []
        for index in 0..<40 {
            beats += detector.process(frame(atIndex: index, bass: index == 30 ? 0.96 : 0.6))
        }
        XCTAssertEqual(beats.filter { $0.band == .bass }.count, 1,
                       "A kick at 1.6 times the rolling bass mean is a beat with the marker at 70 percent.")
    }

    /// The other end: on the same replays a marker near the bottom asked for 1.1 times
    /// the mean and fired eight beats a second, which lit the room solid instead of
    /// pulsing it. A swell of 15 percent over the mean is not a hit even there.
    func testASwellOfFifteenPercentIsNotABeatEvenWithTheMarkerLow() {
        var detector = BeatDetector(sensitivity: 0.95)
        var beats: [BeatEvent] = []
        for index in 0..<40 {
            beats += detector.process(frame(atIndex: index, bass: index == 30 ? 0.69 : 0.6))
        }
        XCTAssertTrue(beats.isEmpty,
                      "A 15 percent swell over the rolling mean must not fire even at the most sensitive end.")
    }
}
