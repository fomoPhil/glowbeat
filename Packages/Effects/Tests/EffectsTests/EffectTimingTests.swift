import XCTest
@testable import Effects

final class EffectTimingTests: XCTestCase {

    /// One tick at the default ten updates a second.
    private let tickInterval: TimeInterval = 0.1
    private let frame = AudioFrame(time: 0, rms: 1, bands: BandEnergies([1, 1, 1, 1, 1]))
    /// One beat in every group, so Spread's mid group, the one that reports a hit whole,
    /// is lit alongside Pulse's and Wave's.
    private let everyBand = [BeatEvent(band: .bass, time: 0, energy: 1),
                             BeatEvent(band: .mid, time: 0, energy: 1),
                             BeatEvent(band: .highMid, time: 0, energy: 1)]

    /// The three beat driven effects. Glow has its own follower and its own tests.
    private let beatEffects: [EffectKind] = [.pulse, .wave, .spread]

    /// The strongest bulb one tick after a beat, with `snap` on the slider. The session
    /// is opened with a quiet tick first: the very first tick of a session has no elapsed
    /// time to ramp over, so it is the one after it that shows the ramp.
    private func peakOneTickAfterABeat(_ kind: EffectKind, snap: Double) -> Double {
        var effect = kind.makeEffect()
        effect.setTiming(EffectTiming.from(snap: snap, fade: EffectTiming.standardFade))
        _ = effect.tick(beats: [], frame: frame, bulbCount: 3, palette: .party, time: 0)
        let hit = effect.tick(beats: everyBand, frame: frame, bulbCount: 3,
                              palette: .party, time: tickInterval)
        return hit.map(\.intensity).max() ?? 0
    }

    func testSnapAtFullIsInstantAndAtZeroIsAQuarterSecond() {
        XCTAssertEqual(EffectTiming.from(snap: 1, fade: 0.5).attack, 0, accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.from(snap: 0, fade: 0.5).attack, 0.25, accuracy: 0.0001)
    }

    func testFadeSpansTheReleaseRangeOnALogScale() {
        XCTAssertEqual(EffectTiming.from(snap: 0.5, fade: 0).release, 0.15, accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.from(snap: 0.5, fade: 1).release, 5.0, accuracy: 0.0001)
        let middle = EffectTiming.from(snap: 0.5, fade: 0.5).release
        XCTAssertEqual(middle, sqrt(0.15 * 5.0), accuracy: 0.0001)
    }

    /// The top of the slider is what Phil asked to move, and the default has to stay
    /// where it was: the shipped Fade is stated as the half second settle it produces,
    /// so a longer ceiling moves the slider position under it, not the feel.
    func testRaisingTheCeilingLeavesTheShippedFadeAtHalfASecond() {
        XCTAssertEqual(EffectTiming.slowestRelease, 5.0, accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.release(forFade: EffectTiming.standardFade), 0.5,
                       accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.fade(forRelease: 5.0), 1, accuracy: 0.0001)
        // A release past the top reads back as the top rather than as a fade above 1.
        XCTAssertEqual(EffectTiming.fade(forRelease: 9), 1, accuracy: 0.0001)
    }

    func testSliderValuesOutsideZeroToOneAreClamped() {
        XCTAssertEqual(EffectTiming.from(snap: 7, fade: -3).attack, 0, accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.from(snap: 7, fade: -3).release, 0.15, accuracy: 0.0001)
    }

    func testPulseSettlesOverTheFadeTheUserAsksFor() {
        var effect = PulseEffect()
        effect.setTiming(EffectTiming(attack: 0, release: 2.0))
        let frame = AudioFrame(time: 0, rms: 1, bands: BandEnergies([1, 1, 1, 1, 1]))
        let beat = BeatEvent(band: .bass, time: 0, energy: 1)
        _ = effect.tick(beats: [beat], frame: frame, bulbCount: 1, palette: .party, time: 0)
        let halfway = effect.tick(beats: [], frame: frame, bulbCount: 1, palette: .party, time: 1.0)
        XCTAssertEqual(halfway[0].intensity, 0.5, accuracy: 0.01)
        let settled = effect.tick(beats: [], frame: frame, bulbCount: 1, palette: .party, time: 2.1)
        XCTAssertEqual(settled[0].intensity, 0, accuracy: 0.0001)
    }

    /// Snap and Fade retune what is already running. Dragging either may change how
    /// bright the room is, which is the point, but it may never jump the palette: the
    /// color has to carry on from where it was.
    func testEveryEffectAcceptsATimingWithoutChangingItsHue() {
        for kind in EffectKind.allCases {
            var effect = kind.makeEffect()
            let beat = BeatEvent(band: .bass, time: 0, energy: 1)
            let before = effect.tick(beats: [beat], frame: frame, bulbCount: 2, palette: .party, time: 0)
            effect.setTiming(EffectTiming.from(snap: 0.2, fade: 0.9))
            // The second tick is at the same instant as the first, so nothing but
            // `setTiming` can have moved the color: Glow's hue drifts with elapsed time.
            let after = effect.tick(beats: [], frame: frame, bulbCount: 2, palette: .party, time: 0)
            XCTAssertEqual(before.count, 2, "\(kind)")
            XCTAssertEqual(after.count, 2, "\(kind)")
            XCTAssertEqual(before.map(\.color), after.map(\.color),
                           "\(kind) changed hue when the timing changed.")
        }
    }

    /// The critical half of Snap: it is one control for the whole room, so the three beat
    /// driven effects ramp up over it too. Before this they jumped straight to a full hit
    /// and only Glow listened, which made the slider look broken on Pulse, Wave and Spread.
    func testASlowSnapRampsPulseWaveAndSpreadUpInsteadOfJumping() {
        for kind in beatEffects {
            let peak = peakOneTickAfterABeat(kind, snap: 0)
            XCTAssertGreaterThan(peak, 0, "\(kind) did not react to the beat at all.")
            XCTAssertLessThan(peak, 1, "\(kind) jumped to a full hit despite Snap at zero.")
        }
    }

    /// And the other end: Snap at the top still reads as instant, because the ramp
    /// finishes inside a single tick.
    func testAFullSnapStillLandsAFullHitInOneTick() {
        for kind in beatEffects {
            XCTAssertGreaterThanOrEqual(peakOneTickAfterABeat(kind, snap: 1), 0.99, "\(kind)")
        }
    }

    /// The default has to land a beat inside one tick, because that is what these three
    /// effects did before Snap existed and the slider must not cost anyone their feel.
    /// `beatAttackScale` is what buys it: the same slider position gives Glow a 50 ms
    /// breath and a beat a 10 ms crack.
    func testTheDefaultSnapStillLandsAFullHitInOneTick() {
        for kind in beatEffects {
            XCTAssertGreaterThanOrEqual(peakOneTickAfterABeat(kind, snap: EffectTiming.standardSnap),
                                        0.99, "\(kind) went soft at the default Snap.")
        }
    }

    /// The other half of that trade. Glow follows a level rather than reacting to an
    /// impulse, so it keeps the whole attack and breathes in over a couple of ticks at
    /// the same slider position.
    func testGlowKeepsTheWholeAttackAtTheDefaultSnap() {
        var effect = GlowEffect()
        effect.setTiming(.standard)
        _ = effect.tick(beats: [], frame: frame, bulbCount: 1, palette: .party, time: 0)
        let afterOneTick = effect.tick(beats: [], frame: frame, bulbCount: 1,
                                       palette: .party, time: tickInterval)
        XCTAssertLessThan(afterOneTick[0].intensity, 0.9,
                          "Glow must not crack on the way a beat does.")
        let afterThree = effect.tick(beats: [], frame: frame, bulbCount: 1,
                                     palette: .party, time: 3 * tickInterval)
        XCTAssertGreaterThan(afterThree[0].intensity, 0.9, "And it must still get there.")
    }

    /// Snap is an attack, not a brightness: a soft Snap makes a hit take longer to arrive
    /// rather than stopping it partway up. The level keeps climbing on the ticks after
    /// the beat, with no further beats, and gets there.
    func testASlowSnapKeepsClimbingAfterTheBeatUntilItReachesAFullHit() {
        for kind in beatEffects {
            var effect = kind.makeEffect()
            effect.setTiming(EffectTiming.from(snap: 0, fade: 1))
            // Enough bulbs that Wave's rising cell is still in the room at the last tick,
            // and enough ticks to cover the ramp Snap at zero asks for.
            let bulbCount = 16
            _ = effect.tick(beats: [], frame: frame, bulbCount: bulbCount, palette: .party, time: 0)
            var peaks: [Double] = []
            for step in 1...3 {
                let beats = step == 1 ? everyBand : []
                let outputs = effect.tick(beats: beats, frame: frame, bulbCount: bulbCount,
                                          palette: .party, time: Double(step) * tickInterval)
                peaks.append(outputs.map(\.intensity).max() ?? 0)
            }
            XCTAssertEqual(peaks, peaks.sorted(), "\(kind) fell back before reaching a full hit.")
            XCTAssertEqual(peaks.last ?? 0, 1, accuracy: 0.0001,
                           "\(kind) never arrived at a full hit.")
        }
    }
}
