import XCTest
@testable import Effects

final class GlowEffectTests: XCTestCase {

    private let palette = Palette.party
    /// One color, so the crossfade is a no op and the brightness can be read exactly.
    private let onePalette = Palette(id: "one",
                                     name: "One",
                                     colors: [RGB(hex: 0x00FF00)],
                                     dimBase: RGB(hex: 0x101010))

    /// Ten ticks a second, the rate the engine runs at.
    private let step: TimeInterval = 0.1

    /// Drives the effect for `seconds` at a steady level and returns the color every bulb
    /// was given on the last tick. The clock carries on between calls, the way it does in
    /// a real session.
    private func drive(_ effect: inout GlowEffect,
                       clock: inout TimeInterval,
                       rms: Float,
                       seconds: TimeInterval,
                       palette: Palette,
                       beats: [BeatEvent] = [],
                       bulbCount: Int = 3) -> RGB {
        var last = palette.dimBase
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            clock += step
            elapsed += step
            let frame = AudioFrame(time: clock, rms: rms, bands: .zero)
            let colors = effect.tickColors(beats: beats,
                                           frame: frame,
                                           bulbCount: bulbCount,
                                           palette: palette,
                                           time: clock)
            XCTAssertEqual(colors.count, bulbCount)
            XCTAssertEqual(Set(colors).count, 1, "Glow lights every bulb the same color.")
            last = colors[0]
        }
        return last
    }

    func testKindAndBlurb() {
        XCTAssertEqual(GlowEffect().kind, .glow)
        XCTAssertEqual(EffectKind.glow.displayName, "Glow")
        XCTAssertEqual(EffectKind.glow.summary,
                       "Louder is brighter. Color drifts through the palette.")
        XCTAssertTrue(EffectKind.allCases.contains(.glow))
        XCTAssertEqual(EffectKind.glow.makeEffect().kind, .glow)
    }

    func testSilenceSitsAtTheDimBase() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        let color = drive(&effect, clock: &clock, rms: 0, seconds: 2, palette: onePalette)
        XCTAssertEqual(color, onePalette.dimBase)
    }

    func testSustainedLoudReachesThePaletteColor() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        let color = drive(&effect, clock: &clock, rms: 1, seconds: 2, palette: onePalette)
        XCTAssertEqual(color, onePalette.colors[0])
    }

    /// Breathing rather than strobing: the rise is quick and the fall takes long enough
    /// that a gap between beats does not read as a flicker.
    func testABurstRisesFastAndFallsSlowly() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        // Two ticks: the first one only sets the clock, so 100 ms of audio have passed.
        let afterBurst = drive(&effect, clock: &clock, rms: 1, seconds: 0.2, palette: onePalette)
        XCTAssertGreaterThan(afterBurst.g, 200, "A 50 ms attack is most of the way up in 100 ms.")

        _ = drive(&effect, clock: &clock, rms: 1, seconds: 1, palette: onePalette)
        let shortlyAfter = drive(&effect, clock: &clock, rms: 0, seconds: 0.2,
                                 palette: onePalette)
        XCTAssertGreaterThan(shortlyAfter.g, 128, "A 400 ms release is still lit after 200 ms.")

        let settled = drive(&effect, clock: &clock, rms: 0, seconds: 3, palette: onePalette)
        XCTAssertEqual(settled, onePalette.dimBase)
    }

    func testTheColorDriftsThroughThePaletteOverTime() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        let first = drive(&effect, clock: &clock, rms: 1, seconds: 0.5, palette: palette)
        XCTAssertLessThan(first.channelDistance(to: palette.colors[0]), 12,
                          "It starts on the palette's first color.")

        let midway = drive(&effect, clock: &clock, rms: 1, seconds: 3.5, palette: palette)
        XCTAssertGreaterThan(midway.channelDistance(to: palette.colors[0]), 20,
                             "Halfway through a color's turn it has visibly moved on.")

        let next = drive(&effect, clock: &clock, rms: 1, seconds: 4, palette: palette)
        XCTAssertLessThan(next.channelDistance(to: palette.colors[1]), 12,
                          "After about eight seconds it has arrived at the next color.")
    }

    /// Glow is volume driven, so a room full of beats with no volume behind them stays
    /// dark. That is the whole difference between it and Pulse.
    func testBeatsAreIgnored() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        let beats = [BeatEvent(band: .bass, time: 0, energy: 1)]
        let color = drive(&effect, clock: &clock, rms: 0, seconds: 1,
                          palette: onePalette, beats: beats)
        XCTAssertEqual(color, onePalette.dimBase)
    }

    /// The gate is where the brightness starts from, so the first level the user has
    /// chosen to react to is the dimmest lit color rather than an already bright one.
    func testBrightnessIsMeasuredFromTheGate() {
        XCTAssertEqual(GlowEffect.brightness(level: 0.5, gate: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(GlowEffect.brightness(level: 0.75, gate: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(GlowEffect.brightness(level: 1, gate: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(GlowEffect.brightness(level: 0.2, gate: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(GlowEffect.brightness(level: 0.3, gate: 0), 0.3, accuracy: 0.0001)
        // A gate pinned at the top leaves only a full scale signal lit.
        XCTAssertEqual(GlowEffect.brightness(level: 0.99, gate: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(GlowEffect.brightness(level: 1, gate: 1), 1, accuracy: 0.0001)
    }

    func testTheGateShiftsTheLevelTheGlowStartsAt() {
        var effect = GlowEffect()
        effect.setGate(0.5)
        var clock: TimeInterval = 0
        let atTheGate = drive(&effect, clock: &clock, rms: 0.5, seconds: 2, palette: onePalette)
        XCTAssertEqual(atTheGate, onePalette.dimBase, "At the gate the glow is not yet lit.")

        let loud = drive(&effect, clock: &clock, rms: 1, seconds: 2, palette: onePalette)
        XCTAssertEqual(loud, onePalette.colors[0])
    }

    func testZeroBulbsReturnsAnEmptyArray() {
        var effect = GlowEffect()
        let frame = AudioFrame(time: 0, rms: 1, bands: .zero)
        XCTAssertTrue(effect.tickColors(beats: [], frame: frame, bulbCount: 0,
                                        palette: palette, time: 0).isEmpty)
    }

    func testAPaletteWithNoColorsStaysAtTheDimBase() {
        var effect = GlowEffect()
        let empty = Palette(id: "empty", name: "Empty", colors: [], dimBase: RGB(hex: 0x0A0A0A))
        var clock: TimeInterval = 0
        XCTAssertEqual(drive(&effect, clock: &clock, rms: 1, seconds: 2, palette: empty),
                       empty.dimBase)
    }

    func testResetReturnsToTheDimBaseAndTheFirstColor() {
        var effect = GlowEffect()
        var clock: TimeInterval = 0
        _ = drive(&effect, clock: &clock, rms: 1, seconds: 5, palette: palette)
        effect.reset()
        let afterReset = drive(&effect, clock: &clock, rms: 0, seconds: 0.1, palette: palette)
        XCTAssertEqual(afterReset, palette.dimBase)

        let relit = drive(&effect, clock: &clock, rms: 1, seconds: 0.4, palette: palette)
        XCTAssertLessThan(relit.channelDistance(to: palette.colors[0]), 20,
                          "A reset starts the drift over at the first color.")
    }

    // MARK: Confetti

    /// "Each bulb drifts through the palette from its own scattered start": neighbors
    /// never match, and every bulb keeps drifting.
    func testConfettiDriftsEachBulbFromItsOwnStart() {
        var effect = GlowEffect()
        effect.setConfetti(true)
        var first: [RGB] = []
        for step in 0..<120 {
            let time = Double(step) * 0.1
            let colors = effect.tick(beats: [], frame: AudioFrame(time: time, rms: 1, bands: .zero),
                                     bulbCount: 7, palette: palette, time: time).map(\.color)
            if step == 10 { first = colors }
            if step >= 10 {
                for index in 1..<colors.count where colors[index] == colors[index - 1] {
                    XCTFail("Tick \(step): bulbs \(index - 1) and \(index) match.")
                }
            }
            if step == 119 {
                for index in colors.indices {
                    XCTAssertNotEqual(colors[index], first[index], "Bulb \(index) did not drift.")
                }
            }
        }
    }

    /// Turning confetti on fades the room apart over 0.4 s rather than cutting.
    func testTurningConfettiOnFadesTheRoomApart() {
        var effect = GlowEffect()
        let frame = AudioFrame(time: 0, rms: 1, bands: .zero)
        let together = effect.tick(beats: [], frame: frame, bulbCount: 5, palette: palette,
                                   time: 0).map(\.color)
        XCTAssertEqual(Set(together).count, 1)
        effect.setConfetti(true)
        let starting = effect.tick(beats: [], frame: frame, bulbCount: 5, palette: palette,
                                   time: 0.1).map(\.color)
        XCTAssertEqual(Set(starting).count, 1,
                       "The tick the switch lands on still shows the one color.")
        XCTAssertLessThanOrEqual(starting[0].channelDistance(to: together[0]), 4,
                                 "Only a tenth of a second of drift apart.")
        let apart = effect.tick(beats: [], frame: frame, bulbCount: 5, palette: palette,
                                time: 0.5).map(\.color)
        XCTAssertGreaterThan(Set(apart).count, 1)
    }

    /// Beat driven effects have nothing to do with the gate, and must not be broken by
    /// the engine handing it to every effect it builds.
    func testTheGateIsANoOpForBeatDrivenEffects() {
        for kind in EffectKind.allCases where kind != .glow {
            var effect = kind.makeEffect()
            effect.setGate(0.9)
            let frame = AudioFrame(time: 0, rms: 1, bands: .zero)
            let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 1)],
                                           frame: frame,
                                           bulbCount: 3,
                                           palette: palette,
                                           time: 0)
            XCTAssertEqual(colors.count, 3, "\(kind.displayName) stopped producing colors.")
            XCTAssertTrue(colors.contains { $0 != palette.dimBase },
                          "\(kind.displayName) stopped reacting to a beat.")
        }
    }
}
