import XCTest
@testable import Effects

final class WaveEffectTests: XCTestCase {

    private let palette = Palette.party
    private let quietFrame = AudioFrame(time: 0, rms: 0, bands: .zero)

    private func tick(_ effect: inout WaveEffect,
                      beat: Bool,
                      bulbCount: Int,
                      at time: TimeInterval) -> [RGB] {
        let beats = beat ? [BeatEvent(band: .bass, time: time, energy: 0.9)] : []
        return effect.tickColors(beats: beats,
                                 frame: quietFrame,
                                 bulbCount: bulbCount,
                                 palette: palette,
                                 time: time)
    }

    /// The bulb furthest from the dim base, or nil when every bulb is at the dim base.
    private func brightestBulb(in colors: [RGB]) -> Int? {
        var brightest: Int?
        var best = 0
        for (index, color) in colors.enumerated() {
            let distance = color.channelDistance(to: palette.dimBase)
            if distance > best {
                best = distance
                brightest = index
            }
        }
        return brightest
    }

    func testABeatPushesAColorIntoTheFirstBulb() {
        var effect = WaveEffect()
        let colors = tick(&effect, beat: true, bulbCount: 4, at: 0)
        XCTAssertEqual(colors[0], palette.colors[0])
        XCTAssertEqual(Array(colors[1...]), Array(repeating: palette.dimBase, count: 3))
    }

    func testTheBrightestBulbAdvancesOnePositionPerTick() {
        var effect = WaveEffect()
        let first = tick(&effect, beat: true, bulbCount: 4, at: 0)
        XCTAssertEqual(brightestBulb(in: first), 0)

        let second = tick(&effect, beat: false, bulbCount: 4, at: 0.125)
        XCTAssertEqual(brightestBulb(in: second), 1)
        XCTAssertEqual(second[0], palette.dimBase)
        XCTAssertEqual(second[2], palette.dimBase)
        XCTAssertEqual(second[3], palette.dimBase)

        let third = tick(&effect, beat: false, bulbCount: 4, at: 0.25)
        XCTAssertEqual(brightestBulb(in: third), 2)
        XCTAssertEqual(third[0], palette.dimBase)
        XCTAssertEqual(third[1], palette.dimBase)
        XCTAssertEqual(third[3], palette.dimBase)
    }

    func testTheTravelingColorRampsDownAsItMoves() {
        var effect = WaveEffect()
        _ = tick(&effect, beat: true, bulbCount: 4, at: 0)
        let second = tick(&effect, beat: false, bulbCount: 4, at: 0.125)
        let third = tick(&effect, beat: false, bulbCount: 4, at: 0.25)

        // Part way down: lit, but no longer the full palette color.
        XCTAssertGreaterThan(second[1].channelDistance(to: palette.dimBase), 0)
        XCTAssertGreaterThan(second[1].channelDistance(to: palette.colors[0]), 0)
        // Dimmer one tick later.
        XCTAssertLessThan(third[2].channelDistance(to: palette.dimBase),
                          second[1].channelDistance(to: palette.dimBase))
    }

    func testACellSettlesAtTheDimBaseAfterAboutHalfASecond() {
        var effect = WaveEffect()
        _ = tick(&effect, beat: true, bulbCount: 8, at: 0)
        var colors = tick(&effect, beat: false, bulbCount: 8, at: 0.125)
        for step in 2...5 {
            colors = tick(&effect, beat: false, bulbCount: 8, at: Double(step) * 0.125)
        }
        // 0.625 s after the beat, with the cell still on a bulb, it is back at the dim base.
        XCTAssertEqual(colors, Array(repeating: palette.dimBase, count: 8))
    }

    func testTheColorLeavesTheRoomAfterEnoughTicks() {
        var effect = WaveEffect()
        _ = tick(&effect, beat: true, bulbCount: 3, at: 0)
        _ = tick(&effect, beat: false, bulbCount: 3, at: 0.125)
        _ = tick(&effect, beat: false, bulbCount: 3, at: 0.25)
        let gone = tick(&effect, beat: false, bulbCount: 3, at: 0.375)
        XCTAssertEqual(gone, Array(repeating: palette.dimBase, count: 3))
        XCTAssertNil(brightestBulb(in: gone))
    }

    /// Every beat pushes a highlight, and the color it pushes is the color clock's: the
    /// second beat of a phrase pushes the same color as the first.
    func testEveryBeatPushesTheColorClocksColor() {
        var effect = WaveEffect()
        // Full Snap, so the second beat lands on its palette color rather than partway up
        // the ramp: this test is about which color, not about how fast it arrives.
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        _ = tick(&effect, beat: true, bulbCount: 3, at: 0)
        let second = tick(&effect, beat: true, bulbCount: 3, at: 0.125)
        XCTAssertEqual(second[0], palette.colors[0])
        // The first beat's highlight is one bulb along, now part way through its fade.
        XCTAssertGreaterThan(second[1].channelDistance(to: palette.dimBase), 0)
        XCTAssertGreaterThan(second[1].channelDistance(to: palette.colors[0]), 0)
    }

    /// When the clock moves on, the head of the wave crossfades to the new color rather
    /// than cutting to it, even while it waits a whole second for its next hop.
    func testTheHeadCrossfadesWhenTheClockMoves() {
        var effect = WaveEffect()
        effect.setTravelSpeed(1)
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        var head: [RGB] = []
        for number in 0..<5 {
            let time = Double(number) * 0.25
            head.append(effect.tick(beats: [BeatEvent(band: .bass, time: time, energy: 0.9)],
                                    frame: quietFrame, bulbCount: 4, palette: palette,
                                    time: time)[0].color)
        }
        XCTAssertEqual(head, Array(repeating: palette.colors[0], count: 5),
                       "The beat that moves the clock still lands on the old color.")
        let midway = effect.tick(beats: [], frame: quietFrame, bulbCount: 4,
                                 palette: palette, time: 1.2)[0].color
        XCTAssertEqual(midway, palette.colors[0].blended(with: palette.colors[1], amount: 0.5))
        let arrived = effect.tick(beats: [], frame: quietFrame, bulbCount: 4,
                                  palette: palette, time: 1.4)[0].color
        XCTAssertEqual(arrived, palette.colors[1])
    }

    /// Bands of color travel: after a change, the bulbs the wave has already filled keep
    /// the old color, the head carries the new one, and the cells pushed during the
    /// crossfade carry the blend between them.
    func testBandsOfColorTravelAlongTheRoom() {
        var effect = WaveEffect()
        // Eight bulbs a second and a tick every 1/8 s: exactly one hop a tick, in times a
        // binary clock represents exactly.
        effect.setTravelSpeed(8)
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        var colors: [EffectOutput] = []
        for step in 0...15 {
            let time = Double(step) * 0.125
            let beats = step % 2 == 0 ? [BeatEvent(band: .bass, time: time, energy: 0.9)] : []
            colors = effect.tick(beats: beats, frame: quietFrame, bulbCount: 8,
                                 palette: palette, time: time)
        }
        // The fifth beat, at 1 s, moved the clock. At 1.875 s the cell on bulb k was pushed
        // at 1.875 - k / 8 s.
        XCTAssertEqual(colors[0].color, palette.colors[1], "The head carries the new color.")
        XCTAssertEqual(colors[7].color, palette.colors[0],
                       "The cell pushed on the changing beat still carries the old one.")
        XCTAssertEqual(colors[5].color, palette.colors[0].blended(with: palette.colors[1],
                                                                  amount: 0.625),
                       "A cell pushed part way through the crossfade carries the blend.")
    }

    func testChangingTheBulbCountRebuildsTheWave() {
        var effect = WaveEffect()
        _ = tick(&effect, beat: true, bulbCount: 3, at: 0)
        let resized = tick(&effect, beat: false, bulbCount: 5, at: 0.125)
        XCTAssertEqual(resized, Array(repeating: palette.dimBase, count: 5))
    }

    func testZeroBulbsReturnsAnEmptyArray() {
        var effect = WaveEffect()
        XCTAssertTrue(tick(&effect, beat: true, bulbCount: 0, at: 0).isEmpty)
    }

    func testResetClearsTheWaveAndReturnsToTheStartOfThePalette() {
        var effect = WaveEffect()
        _ = tick(&effect, beat: true, bulbCount: 3, at: 0)
        _ = tick(&effect, beat: true, bulbCount: 3, at: 0.125)
        effect.reset()
        let colors = tick(&effect, beat: true, bulbCount: 3, at: 0.25)
        XCTAssertEqual(colors[0], palette.colors[0])
        XCTAssertEqual(Array(colors[1...]), Array(repeating: palette.dimBase, count: 2))
    }

    // MARK: Travel speed

    func testTheDefaultTravelSpeedIsTenBulbsASecond() {
        XCTAssertEqual(WaveEffect.defaultTravelSpeed, 10, accuracy: 0.0001)
        XCTAssertEqual(WaveEffect().bulbsPerSecond, WaveEffect.defaultTravelSpeed,
                       accuracy: 0.0001)
        XCTAssertEqual(WaveEffect.travelRange.lowerBound, 1, accuracy: 0.0001)
        XCTAssertEqual(WaveEffect.travelRange.upperBound, 15, accuracy: 0.0001)
    }

    func testTheTravelSpeedIsHeldInsideTheSupportedRange() {
        var effect = WaveEffect()
        effect.setTravelSpeed(0.1)
        XCTAssertEqual(effect.bulbsPerSecond, 1, accuracy: 0.0001)
        effect.setTravelSpeed(99)
        XCTAssertEqual(effect.bulbsPerSecond, 15, accuracy: 0.0001)
        XCTAssertEqual(WaveEffect.clampedTravelSpeed(-4), 1, accuracy: 0.0001)
        XCTAssertEqual(WaveEffect.clampedTravelSpeed(7), 7, accuracy: 0.0001)
    }

    /// The default reproduces what Wave did before the slider existed: one bulb per tick
    /// at the ten updates a second the engine runs at.
    func testTheDefaultSpeedHopsOncePerTenthOfASecond() {
        var effect = WaveEffect()
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        _ = tick(&effect, beat: true, bulbCount: 6, at: 0)
        for step in 1...4 {
            let colors = tick(&effect, beat: false, bulbCount: 6, at: Double(step) * 0.1)
            XCTAssertEqual(brightestBulb(in: colors), step)
        }
    }

    func testASlowTravelSpeedKeepsTheColorOnABulbForSeveralTicks() {
        var effect = WaveEffect()
        effect.setTravelSpeed(2)
        // A long settle, so the traveling hit stays readable while it waits to hop.
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        _ = tick(&effect, beat: true, bulbCount: 6, at: 0)
        for step in 1...4 {
            let colors = tick(&effect, beat: false, bulbCount: 6, at: Double(step) * 0.1)
            XCTAssertEqual(brightestBulb(in: colors), 0,
                           "At 2 bulbs/s the color may not leave the first bulb inside "
                           + "half a second.")
        }
        let hopped = tick(&effect, beat: false, bulbCount: 6, at: 0.5)
        XCTAssertEqual(brightestBulb(in: hopped), 1)
    }

    func testAFastTravelSpeedHopsMoreThanOncePerTick() {
        var effect = WaveEffect()
        effect.setTravelSpeed(15)
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        _ = tick(&effect, beat: true, bulbCount: 8, at: 0)
        let colors = tick(&effect, beat: false, bulbCount: 8, at: 0.2)
        XCTAssertEqual(brightestBulb(in: colors), 3,
                       "15 bulbs/s over 200 ms is three bulbs, not one.")
    }

    /// The hop rate must not swallow the beat: however slowly the wave travels, the room
    /// still reacts on the tick the beat lands.
    func testABeatLightsTheFirstBulbBetweenHops() {
        var effect = WaveEffect()
        effect.setTravelSpeed(1)
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        _ = tick(&effect, beat: false, bulbCount: 4, at: 0)
        let lit = tick(&effect, beat: true, bulbCount: 4, at: 0.1)
        XCTAssertEqual(lit[0], palette.colors[0],
                       "A beat has to light the first bulb on the tick it lands rather "
                       + "than waiting for the next hop.")
    }

    /// Intended behavior, not a bug: at a slow travel speed two beats inside one hop
    /// leave only the newer hit, because there is nowhere else for it to go.
    func testASecondBeatBeforeAHopReplacesTheFirstBulb() {
        var effect = WaveEffect()
        effect.setTravelSpeed(1)
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        _ = tick(&effect, beat: true, bulbCount: 4, at: 0)
        let second = tick(&effect, beat: true, bulbCount: 4, at: 0.1)
        XCTAssertEqual(second[0], palette.colors[0])
        XCTAssertEqual(Array(second[1...]), Array(repeating: palette.dimBase, count: 3),
                       "The replaced color must not also be pushed along the room.")
    }

    func testAStallDoesNotBankUpHops() {
        var effect = WaveEffect()
        effect.setTravelSpeed(15)
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        _ = tick(&effect, beat: true, bulbCount: 4, at: 0)
        // Ten minutes between ticks, which is what a paused app comes back from.
        let stalled = tick(&effect, beat: true, bulbCount: 4, at: 600)
        XCTAssertEqual(brightestBulb(in: stalled), 0)
        let next = tick(&effect, beat: false, bulbCount: 4, at: 600.1)
        XCTAssertEqual(brightestBulb(in: next), 1,
                       "A stall must not leave whole hops banked up for the ticks after "
                       + "it.")
    }

    func testResetClearsTheHopAccumulatorAndKeepsTheTravelSpeed() {
        var effect = WaveEffect()
        effect.setTravelSpeed(4)
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        _ = tick(&effect, beat: true, bulbCount: 4, at: 0)
        // Four fifths of a hop banked.
        _ = tick(&effect, beat: false, bulbCount: 4, at: 0.2)
        effect.reset()
        XCTAssertEqual(effect.bulbsPerSecond, 4, accuracy: 0.0001,
                       "Reset restarts the wave, not the speed the user set.")

        _ = tick(&effect, beat: true, bulbCount: 4, at: 1.0)
        let colors = tick(&effect, beat: false, bulbCount: 4, at: 1.2)
        XCTAssertEqual(brightestBulb(in: colors), 0,
                       "A cleared accumulator means 0.2 s at 4 bulbs/s is not yet a hop.")
    }

    // MARK: Confetti

    /// "Each pushed head gets a scattered color that differs from the cell behind it." The
    /// cells travel together, so no two neighbors ever match, at any travel speed, however
    /// the beats land.
    func testConfettiNeverPutsACellNextToOneOfItsOwnColor() {
        for speed in [1.0, 4, 10, 15] {
            var effect = WaveEffect()
            effect.setConfetti(true)
            effect.setTravelSpeed(speed)
            var generator = SeededGenerator(seed: UInt64(speed))
            for step in 0..<300 {
                let time = Double(step) * 0.1
                let beat = Bool.random(using: &generator)
                let outputs = effect.tick(beats: beat ? [BeatEvent(band: .bass, time: time, energy: 0.9)] : [],
                                          frame: quietFrame, bulbCount: 10, palette: palette,
                                          time: time)
                XCTAssertTrue(outputs.allSatisfy { palette.colors.contains($0.color) })
                for index in 1..<outputs.count where outputs[index].color == outputs[index - 1].color {
                    XCTFail("\(speed) bulbs/s, tick \(step): bulbs \(index - 1) and \(index) match.")
                }
            }
        }
    }

    /// The beat still lights the first bulb on the tick it lands, in that cell's own
    /// scattered color.
    func testConfettiStillLightsTheFirstBulbOnTheBeat() {
        var effect = WaveEffect()
        effect.setConfetti(true)
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        let lit = effect.tick(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                              frame: quietFrame, bulbCount: 5, palette: palette, time: 0)
        XCTAssertEqual(lit[0].intensity, 1, accuracy: 0.0001)
        XCTAssertTrue(palette.colors.contains(lit[0].color))
    }

    func testKindIsWave() {
        XCTAssertEqual(WaveEffect().kind, .wave)
    }

    /// Confetti works with every effect, starts off, and survives a reset, which is what a
    /// resume runs: a paused session must come back the way the user left it.
    func testEveryEffectTakesConfettiAndKeepsItThroughAReset() {
        for kind in EffectKind.allCases {
            var effect = kind.makeEffect()
            XCTAssertFalse(effect.confetti, "\(kind.displayName) starts with confetti on.")
            effect.setConfetti(true)
            XCTAssertTrue(effect.confetti, kind.displayName)
            effect.reset()
            XCTAssertTrue(effect.confetti, "\(kind.displayName) lost confetti on a reset.")
            effect.setConfetti(false)
            XCTAssertFalse(effect.confetti, kind.displayName)
        }
    }

    func testTheFactoryBuildsTheMatchingEffectForEveryKind() {
        for kind in EffectKind.allCases {
            XCTAssertEqual(kind.makeEffect().kind, kind)
        }
    }
}
