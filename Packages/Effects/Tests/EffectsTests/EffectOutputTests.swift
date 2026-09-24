import XCTest
@testable import Effects

/// The contract between an effect and the engine: a hue at full strength plus an
/// intensity, and one rule for turning those into the color a bulb is sent.
final class EffectOutputTests: XCTestCase {

    private let palette = Palette.party
    private let quietFrame = AudioFrame(time: 0, rms: 0, bands: .zero)

    private func bassBeat(at time: TimeInterval) -> [BeatEvent] {
        [BeatEvent(band: .bass, time: time, energy: 0.9)]
    }

    func testIntensityIsClampedToZeroThroughOne() {
        XCTAssertEqual(EffectOutput(color: .white, intensity: 4).intensity, 1)
        XCTAssertEqual(EffectOutput(color: .white, intensity: -2).intensity, 0)
    }

    func testCalmDropsTheIntensityAndKeepsTheColor() {
        let output = EffectOutput(color: palette.colors[2], intensity: 0.8)
        XCTAssertEqual(output.calm.intensity, 0)
        XCTAssertEqual(output.calm.color, palette.colors[2])
    }

    func testRenderingPutsCalmAtTheFloorAndAHitAtTheCeiling() {
        let color = RGB(r: 200, g: 100, b: 50)
        let calm = EffectOutput(color: color, intensity: 0).rendered(floor: 0.3, ceiling: 0.6)
        XCTAssertEqual(calm, color.scaled(by: 0.3))

        let hit = EffectOutput(color: color, intensity: 1).rendered(floor: 0.3, ceiling: 0.6)
        XCTAssertEqual(hit, color.scaled(by: 0.6))

        // Halfway lands halfway up the range. One channel step of slack: the midpoint
        // of 0.3 and 0.6 is not exactly 0.45 in binary floating point.
        let half = EffectOutput(color: color, intensity: 0.5).rendered(floor: 0.3, ceiling: 0.6)
        XCTAssertLessThanOrEqual(half.channelDistance(to: color.scaled(by: 0.45)), 1)
        XCTAssertGreaterThan(half.luminance, calm.luminance)
        XCTAssertLessThan(half.luminance, hit.luminance)
    }

    func testAFloorOfZeroStillGivesBlackWhenNothingIsHappening() {
        let output = EffectOutput(color: palette.colors[0], intensity: 0)
        XCTAssertEqual(output.rendered(floor: 0, ceiling: 1), .black)
    }

    /// A pair the UI should never produce. It has to dim, not invert.
    func testACeilingBelowTheFloorIsTreatedAsTheFloor() {
        let color = RGB(r: 200, g: 100, b: 50)
        XCTAssertEqual(EffectOutput(color: color, intensity: 1).rendered(floor: 0.5, ceiling: 0.2),
                       color.scaled(by: 0.5))
    }

    /// Every effect has to report the palette color itself, never a pre dimmed one, or
    /// the brightness range would be applied on top of a fade the effect already did.
    func testEveryEffectReportsFullStrengthColorsAndItsOwnIntensity() {
        for kind in EffectKind.allCases {
            var effect = kind.makeEffect()
            // Several ticks, because Glow's envelope measures elapsed time and a single
            // tick has none: one loud frame is not yet a loud room.
            var hit: [EffectOutput] = []
            for step in 0..<10 {
                let time = Double(step) * 0.1
                hit = effect.tick(beats: bassBeat(at: time),
                                  frame: AudioFrame(time: time, rms: 1, bands: .zero),
                                  bulbCount: 3,
                                  palette: palette,
                                  time: time)
            }
            XCTAssertEqual(hit.count, 3, "\(kind.displayName) must fill every bulb.")
            // The dimmest color in the palette is the floor every reported hue has to
            // clear. An effect that scaled a color down to mean "less of this" would fall
            // under it, which is exactly what Spread used to do to its bass group.
            let dimmest = palette.colors.map(\.luminance).min() ?? 0
            for output in hit {
                XCTAssertGreaterThanOrEqual(output.color.luminance, dimmest * 0.95,
                                            "\(kind.displayName) reported a dimmed color. "
                                                + "Colors are hues; brightness is the "
                                                + "intensity's job.")
                XCTAssertGreaterThanOrEqual(output.intensity, 0, kind.displayName)
                XCTAssertLessThanOrEqual(output.intensity, 1, kind.displayName)
            }
            XCTAssertTrue(hit.contains { $0.intensity > 0 },
                          "\(kind.displayName) should react to a loud beat.")
        }
    }

    func testPulseReportsAFullHitOnABeatAndFadesToNothing() {
        var effect = PulseEffect()
        let hit = effect.tick(beats: bassBeat(at: 0), frame: quietFrame,
                              bulbCount: 2, palette: palette, time: 0)
        XCTAssertEqual(hit.map(\.intensity), [1, 1])
        XCTAssertEqual(hit.map(\.color), [palette.colors[0], palette.colors[0]])

        let faded = effect.tick(beats: [], frame: quietFrame,
                                bulbCount: 2, palette: palette, time: 0.8)
        XCTAssertEqual(faded.map(\.intensity), [0, 0])
        XCTAssertEqual(faded[0].color, palette.colors[0],
                       "The hue is kept, so a calm bulb rests in the palette's color.")
    }

    func testWaveLeavesTheHueBehindItAndOnlyTheIntensityTravels() {
        var effect = WaveEffect()
        _ = effect.tick(beats: bassBeat(at: 0), frame: quietFrame,
                        bulbCount: 3, palette: palette, time: 0)
        let moved = effect.tick(beats: [], frame: quietFrame,
                                bulbCount: 3, palette: palette, time: 0.125)
        XCTAssertGreaterThan(moved[1].intensity, moved[0].intensity)
        XCTAssertEqual(moved[1].color, palette.colors[0])
        XCTAssertEqual(moved[0].color, palette.colors[0],
                       "A bulb the wave has passed keeps the hue and loses the intensity.")
    }

    func testGlowReportsLoudnessAsIntensity() {
        var effect = GlowEffect()
        effect.setGate(0)
        var last: Double = 0
        for step in 0..<20 {
            let time = Double(step) * 0.1
            last = effect.tick(beats: [],
                               frame: AudioFrame(time: time, rms: 1, bands: .zero),
                               bulbCount: 1,
                               palette: palette,
                               time: time)[0].intensity
        }
        XCTAssertGreaterThan(last, 0.9)

        for step in 20..<60 {
            let time = Double(step) * 0.1
            last = effect.tick(beats: [],
                               frame: AudioFrame(time: time, rms: 0, bands: .zero),
                               bulbCount: 1,
                               palette: palette,
                               time: time)[0].intensity
        }
        XCTAssertEqual(last, 0, accuracy: 0.01)
    }

    func testSpreadReportsOneIntensityPerGroup() {
        var effect = SpreadEffect()
        let outputs = effect.tick(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                  frame: quietFrame,
                                  bulbCount: 3,
                                  palette: palette,
                                  time: 0)
        XCTAssertEqual(outputs[0].intensity, 1, accuracy: 0.0001,
                       "The bass group heard the beat and reports all of it: Spread's bass "
                           + "bulbs reach full brightness, told apart by color alone.")
        XCTAssertEqual(outputs[1].intensity, 0)
        XCTAssertEqual(outputs[2].intensity, 0)
    }
}
