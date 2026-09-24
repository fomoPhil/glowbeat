import XCTest
@testable import Effects

final class PulseEffectTests: XCTestCase {

    private let palette = Palette.party
    private let quietFrame = AudioFrame(time: 0, rms: 0, bands: .zero)

    private func bassBeat(at time: TimeInterval) -> [BeatEvent] {
        [BeatEvent(band: .bass, time: time, energy: 0.9)]
    }

    func testEveryBulbGetsTheSameColor() {
        var effect = PulseEffect()
        let colors = effect.tickColors(beats: bassBeat(at: 0),
                                       frame: quietFrame,
                                       bulbCount: 4,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors.count, 4)
        XCTAssertEqual(Set(colors).count, 1)
    }

    func testWithNoBeatsAtAllBulbsSitAtTheDimBase() {
        var effect = PulseEffect()
        let colors = effect.tickColors(beats: [],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors, Array(repeating: palette.dimBase, count: 3))
    }

    func testTheFirstBassBeatShowsTheFirstPaletteColorAtFullBrightness() {
        var effect = PulseEffect()
        let colors = effect.tickColors(beats: bassBeat(at: 0),
                                       frame: quietFrame,
                                       bulbCount: 2,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors, Array(repeating: palette.colors[0], count: 2))
    }

    /// The phrase moves the color: four beats on each palette color, then the next one, and
    /// round again. Read half a second after each beat, once the crossfade has finished.
    func testThePaletteMovesOnEveryFourthBeatAndWraps() {
        var effect = PulseEffect()
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        var seen: [RGB] = []
        for number in 0..<(palette.colors.count * 4 + 1) {
            let time = Double(number)
            _ = effect.tick(beats: bassBeat(at: time), frame: quietFrame, bulbCount: 1,
                            palette: palette, time: time)
            let settled = effect.tick(beats: [], frame: quietFrame, bulbCount: 1,
                                      palette: palette, time: time + 0.5)
            seen.append(settled[0].color)
        }
        let expected = palette.colors.flatMap { Array(repeating: $0, count: 4) } + [palette.colors[0]]
        XCTAssertEqual(seen, expected)
    }

    /// The beat still moves the brightness: every beat is a full hit, including the three
    /// that leave the color where it is.
    func testEveryBeatIsAHitWhileTheColorHolds() {
        var effect = PulseEffect()
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        for number in 0..<8 {
            let time = Double(number)
            let hit = effect.tick(beats: bassBeat(at: time), frame: quietFrame, bulbCount: 2,
                                  palette: palette, time: time)
            XCTAssertEqual(hit[0].intensity, 1, accuracy: 0.0001, "Beat \(number + 1) did not hit.")
            let between = effect.tick(beats: [], frame: quietFrame, bulbCount: 2,
                                      palette: palette, time: time + 0.9)
            XCTAssertEqual(between[0].intensity, 0, accuracy: 0.0001,
                           "Beat \(number + 1) did not settle before the next.")
        }
    }

    /// A color change crossfades: the beat that brings the next color in lands on the old
    /// one, and the new one arrives over the next 0.4 s without a single tick cutting to it.
    func testAColorChangeCrossfadesRatherThanCutting() {
        var effect = PulseEffect()
        for number in 0..<4 {
            _ = effect.tick(beats: bassBeat(at: Double(number)), frame: quietFrame,
                            bulbCount: 1, palette: palette, time: Double(number))
        }
        let old = palette.colors[0]
        let new = palette.colors[1]
        let onTheBeat = effect.tick(beats: bassBeat(at: 4), frame: quietFrame, bulbCount: 1,
                                    palette: palette, time: 4)[0].color
        XCTAssertEqual(onTheBeat, old)
        let midway = effect.tick(beats: [], frame: quietFrame, bulbCount: 1,
                                 palette: palette, time: 4.2)[0].color
        XCTAssertEqual(midway, old.blended(with: new, amount: 0.5))
        let arrived = effect.tick(beats: [], frame: quietFrame, bulbCount: 1,
                                  palette: palette, time: 4.4)[0].color
        XCTAssertEqual(arrived, new)
    }

    func testTheColorDecaysTowardTheDimBaseOverAboutHalfASecond() {
        var effect = PulseEffect()
        _ = effect.tickColors(beats: bassBeat(at: 0),
                              frame: quietFrame,
                              bulbCount: 1,
                              palette: palette,
                              time: 0)

        let midway = effect.tickColors(beats: [],
                                       frame: quietFrame,
                                       bulbCount: 1,
                                       palette: palette,
                                       time: 0.25)[0]
        XCTAssertGreaterThan(midway.channelDistance(to: palette.dimBase), 0)
        XCTAssertGreaterThan(midway.channelDistance(to: palette.colors[0]), 0)

        let settled = effect.tickColors(beats: [],
                                        frame: quietFrame,
                                        bulbCount: 1,
                                        palette: palette,
                                        time: 0.8)[0]
        XCTAssertEqual(settled, palette.dimBase)
    }

    func testZeroBulbsReturnsAnEmptyArray() {
        var effect = PulseEffect()
        XCTAssertTrue(effect.tickColors(beats: bassBeat(at: 0),
                                        frame: quietFrame,
                                        bulbCount: 0,
                                        palette: palette,
                                        time: 0).isEmpty)
    }

    func testSubBassBeatsAlsoTriggerThePulse() {
        var effect = PulseEffect()
        let colors = effect.tickColors(beats: [BeatEvent(band: .subBass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 1,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[0], palette.colors[0])
    }

    func testResetReturnsToTheStartOfThePalette() {
        var effect = PulseEffect()
        for number in 0..<6 {
            _ = effect.tickColors(beats: bassBeat(at: Double(number)), frame: quietFrame,
                                  bulbCount: 1, palette: palette, time: Double(number))
        }
        XCTAssertEqual(effect.tick(beats: [], frame: quietFrame, bulbCount: 1, palette: palette,
                                   time: 6)[0].color,
                       palette.colors[1], "Six beats should have moved the palette on once.")
        effect.reset()
        let colors = effect.tickColors(beats: bassBeat(at: 1.0), frame: quietFrame, bulbCount: 1,
                                       palette: palette, time: 1.0)
        XCTAssertEqual(colors[0], palette.colors[0])
    }

    func testKindIsPulse() {
        XCTAssertEqual(PulseEffect().kind, .pulse)
        XCTAssertEqual(EffectKind.pulse.displayName, "Pulse")
    }

    func testSwitchingToAShorterPaletteAfterAdvancingIsSafe() {
        var effect = PulseEffect()
        // Sixteen beats walk the clock onto Party's fifth color.
        let beats = Palette.party.colors.count * 4 - 3
        for number in 0..<beats {
            let time = Double(number) * 0.25
            _ = effect.tickColors(beats: bassBeat(at: time), frame: quietFrame, bulbCount: 1,
                                  palette: .party, time: time)
        }
        let last = Double(beats - 1) * 0.25

        // The clock now sits on Party's fifth color, and Warm white only has four.
        let shorter = Palette.warmWhite
        // 0.4 s on: the crossfade has arrived and the half second Fade is still lit.
        let midway = effect.tick(beats: [], frame: quietFrame, bulbCount: 1,
                                 palette: shorter, time: last + 0.4)[0]
        XCTAssertEqual(midway.color, shorter.colors[0],
                       "The fifth color of a four color palette is its first, not off its end.")
        XCTAssertGreaterThan(midway.intensity, 0)

        let settled = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 1,
                                        palette: shorter, time: last + 1)[0]
        XCTAssertEqual(settled, shorter.dimBase)
    }

    // MARK: Confetti

    /// "Every bulb flashes on the beat in its own color": one shared hit, a palette color
    /// per bulb, and no bulb the same color as the one beside it.
    func testConfettiFlashesEveryBulbInItsOwnColor() {
        var effect = PulseEffect()
        effect.setConfetti(true)
        XCTAssertTrue(effect.confetti)
        let hit = effect.tick(beats: bassBeat(at: 0), frame: quietFrame, bulbCount: 8,
                              palette: palette, time: 0)
        XCTAssertEqual(Set(hit.map(\.intensity)), [1])
        XCTAssertTrue(hit.allSatisfy { palette.colors.contains($0.color) })
        for index in 1..<hit.count {
            XCTAssertNotEqual(hit[index].color, hit[index - 1].color, "Bulbs \(index - 1) and \(index)")
        }
        XCTAssertGreaterThan(Set(hit.map(\.color)).count, 1)
    }

    /// The scatter holds for four beats and moves at the color change, crossfading.
    func testConfettiRescattersAtTheColorChange() {
        var effect = PulseEffect()
        effect.setConfetti(true)
        var colors: [[RGB]] = []
        for number in 0..<5 {
            colors.append(effect.tick(beats: bassBeat(at: Double(number)), frame: quietFrame,
                                      bulbCount: 6, palette: palette,
                                      time: Double(number)).map(\.color))
        }
        XCTAssertEqual(Set(colors.prefix(5)).count, 1, "The scatter holds until the change lands.")
        let midway = effect.tick(beats: [], frame: quietFrame, bulbCount: 6, palette: palette,
                                 time: 4.2).map(\.color)
        let arrived = effect.tick(beats: [], frame: quietFrame, bulbCount: 6, palette: palette,
                                  time: 4.4).map(\.color)
        for index in 0..<6 {
            XCTAssertNotEqual(arrived[index], colors[4][index], "Bulb \(index) did not move.")
            XCTAssertEqual(midway[index], colors[4][index].blended(with: arrived[index], amount: 0.5),
                           "Bulb \(index) cut rather than crossfading.")
        }
    }

    func testTheDecayKeepsRunningWhileNoBulbsAreSelected() {
        var effect = PulseEffect()
        _ = effect.tickColors(beats: bassBeat(at: 0), frame: quietFrame, bulbCount: 1,
                              palette: palette, time: 0)

        for step in 1...8 {
            let colors = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 0,
                                           palette: palette, time: Double(step) * 0.125)
            XCTAssertTrue(colors.isEmpty)
        }

        let resumed = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 1,
                                        palette: palette, time: 1.125)
        XCTAssertEqual(resumed, [palette.dimBase])
    }
}
