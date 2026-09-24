import XCTest
@testable import Effects

final class SpreadEffectTests: XCTestCase {

    private let palette = Palette.party
    private let quietFrame = AudioFrame(time: 0, rms: 0, bands: .zero)

    /// The three groups draw one hue family from the same palette color: the bass group
    /// carries a deeper relative of it, the mid group carries it whole, and the high group
    /// carries a lighter relative of it. All three report the whole hit: Phil's call on
    /// 2026-09-23 is bass at full brightness, told apart by color alone.
    ///
    /// The bass tone is the effect's own rule, pinned separately below by its properties
    /// and by a handful of worked values; these tests are about which bulbs light.
    private func bassLit(_ color: RGB, in palette: Palette? = nil) -> RGB {
        let palette = palette ?? self.palette
        guard let index = palette.colors.firstIndex(of: color) else { return color }
        return SpreadEffect.bassTone(at: index, in: palette)
    }
    private func midTone(_ color: RGB) -> RGB { color }
    /// Restates the rule rather than calling into the effect: 45 percent toward white,
    /// deepened where that would not clear the minimum step, clamped at white.
    private func highTone(_ color: RGB) -> RGB {
        let headroom = 255 - color.luminance
        guard headroom > 0 else { return color }
        let amount = min(1, max(SpreadEffect.highlightAmount,
                                SpreadEffect.minimumHighlightStep / headroom))
        return color.blended(with: .white, amount: amount)
    }

    private let allThree = [BeatEvent(band: .bass, time: 0, energy: 0.9),
                            BeatEvent(band: .mid, time: 0, energy: 0.8),
                            BeatEvent(band: .highMid, time: 0, energy: 0.7)]

    /// Walks the color clock onto palette color `index` and lights all three groups there,
    /// once the crossfade has finished: `4 * index + 1` beats a quarter second apart move it
    /// on `index` times, then one more beat half a second later lands on the settled color
    /// without counting toward the next change.
    private func room(of palette: Palette,
                      at index: Int,
                      bulbCount: Int = 3,
                      effect: inout SpreadEffect) -> [RGB] {
        let beats = 4 * index + 1
        for number in 0..<beats {
            _ = effect.tick(beats: allThree, frame: quietFrame, bulbCount: bulbCount,
                            palette: palette, time: Double(number) * 0.25)
        }
        let read = Double(beats - 1) * 0.25 + 0.5
        return effect.tickColors(beats: allThree, frame: quietFrame, bulbCount: bulbCount,
                                 palette: palette, time: read)
    }

    func testWithNoBeatsEveryBulbSitsAtTheDimBase() {
        var effect = SpreadEffect()
        let colors = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 6,
                                       palette: palette, time: 0)
        XCTAssertEqual(colors, Array(repeating: palette.dimBase, count: 6))
    }

    func testABassBeatLightsOnlyTheBassBulbs() {
        var effect = SpreadEffect()
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 6,
                                       palette: palette,
                                       time: 0)
        // Bulbs are dealt round robin: 0 and 3 are bass, 1 and 4 mid, 2 and 5 high.
        XCTAssertEqual(colors[0], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[3], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], palette.dimBase)
        XCTAssertEqual(colors[4], palette.dimBase)
        XCTAssertEqual(colors[5], palette.dimBase)
    }

    func testAHighMidBeatLightsOnlyTheHighBulbs() {
        var effect = SpreadEffect()
        let colors = effect.tickColors(beats: [BeatEvent(band: .highMid, time: 0, energy: 0.8)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[0], palette.dimBase)
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], highTone(palette.colors[0]))
    }

    func testASubBassBeatCountsAsBassAndALowMidBeatCountsAsMid() {
        var effect = SpreadEffect()
        let colors = effect.tickColors(beats: [BeatEvent(band: .subBass, time: 0, energy: 0.9),
                                               BeatEvent(band: .lowMid, time: 0, energy: 0.7)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[0], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[1], midTone(palette.colors[0]))
        XCTAssertEqual(colors[2], palette.dimBase)
    }

    func testEachGroupDecaysBackToTheDimBase() {
        var effect = SpreadEffect()
        _ = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                              frame: quietFrame, bulbCount: 3, palette: palette, time: 0)
        let settled = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 3,
                                        palette: palette, time: 0.6)
        XCTAssertEqual(settled, Array(repeating: palette.dimBase, count: 3))
    }

    func testZeroBulbsReturnsAnEmptyArray() {
        var effect = SpreadEffect()
        XCTAssertTrue(effect.tickColors(beats: [], frame: quietFrame, bulbCount: 0,
                                        palette: palette, time: 0).isEmpty)
    }

    func testKindIsSpread() {
        XCTAssertEqual(SpreadEffect().kind, .spread)
    }

    func testTheBeatenGroupPassesThroughAMidpointOnItsWayDown() {
        var effect = SpreadEffect()
        _ = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                              frame: quietFrame, bulbCount: 3, palette: palette, time: 0)

        let midway = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 3,
                                       palette: palette, time: 0.2)[0]
        XCTAssertGreaterThan(midway.channelDistance(to: palette.dimBase), 0)
        XCTAssertGreaterThan(midway.channelDistance(to: bassLit(palette.colors[0])), 0)

        let settled = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 3,
                                        palette: palette, time: 0.6)[0]
        XCTAssertEqual(settled, palette.dimBase)
    }

    /// The point of the tonal shift: with one color in the palette the room still reads
    /// as dark at the bass end and bright at the top, rather than as three flat copies of
    /// the same color.
    func testTheThreeGroupsAreOneHueFamilyFromDarkToLight() {
        let single = Palette(id: "one", name: "One",
                             colors: [RGB(hex: 0x3060C0)], dimBase: RGB(hex: 0x050505))
        var effect = SpreadEffect()
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9),
                                               BeatEvent(band: .mid, time: 0, energy: 0.8),
                                               BeatEvent(band: .highMid, time: 0, energy: 0.7)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: single,
                                       time: 0)
        XCTAssertLessThan(colors[0].luminance, colors[1].luminance)
        XCTAssertLessThan(colors[1].luminance, colors[2].luminance)
        XCTAssertEqual(colors[0], bassLit(single.colors[0], in: single))
        XCTAssertEqual(colors[1], midTone(single.colors[0]))
        XCTAssertEqual(colors[2], highTone(single.colors[0]))
    }

    /// All three groups share one color clock, and only a bass beat moves it, so the whole
    /// room changes hue together instead of drifting apart.
    func testEveryGroupAdvancesTogetherOnBassBeats() {
        var effect = SpreadEffect()
        let first = effect.tickColors(beats: allThree, frame: quietFrame, bulbCount: 3,
                                      palette: palette, time: 0)
        XCTAssertEqual(first[0], bassLit(palette.colors[0]))
        XCTAssertEqual(first[2], highTone(palette.colors[0]))

        var walked = SpreadEffect()
        let second = room(of: palette, at: 1, effect: &walked)
        XCTAssertEqual(second[0], bassLit(palette.colors[1]))
        XCTAssertEqual(second[1], midTone(palette.colors[1]))
        XCTAssertEqual(second[2], highTone(palette.colors[1]))
    }

    /// Spread follows the color clock like Pulse: four bass beats on each color, and a hit
    /// on every one of them.
    func testTheHueHoldsForFourBassBeats() {
        var effect = SpreadEffect()
        for number in 0..<4 {
            let colors = effect.tickColors(beats: allThree, frame: quietFrame, bulbCount: 3,
                                           palette: palette, time: Double(number) * 0.5)
            XCTAssertEqual(colors[1], midTone(palette.colors[0]), "Beat \(number + 1)")
        }
    }

    /// Every group crossfades to the next color rather than cutting to it, each from its
    /// own shade of the old color to its own shade of the new one.
    func testEveryGroupCrossfadesToTheNextColor() {
        var effect = SpreadEffect()
        effect.setTiming(EffectTiming(attack: 0, release: 5))
        for number in 0..<5 {
            _ = effect.tick(beats: allThree, frame: quietFrame, bulbCount: 3,
                            palette: palette, time: Double(number) * 0.25)
        }
        let midway = effect.tick(beats: [], frame: quietFrame, bulbCount: 3,
                                 palette: palette, time: 1.2)
        let old = palette.colors[0]
        let new = palette.colors[1]
        XCTAssertEqual(midway[1].color, old.blended(with: new, amount: 0.5))
        XCTAssertEqual(midway[2].color, highTone(old).blended(with: highTone(new), amount: 0.5))
    }

    func testOnlyABassBeatMovesThePaletteAlong() {
        var effect = SpreadEffect()
        // Full Snap, one tick apart, so the treble hit lands on the palette color exactly
        // and this reads as a question about the color rather than about the ramp.
        effect.setTiming(EffectTiming.from(snap: 1, fade: EffectTiming.standardFade))
        _ = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                              frame: quietFrame, bulbCount: 3, palette: palette, time: 0)
        let highOnly = effect.tickColors(beats: [BeatEvent(band: .highMid, time: 0.1, energy: 0.7)],
                                         frame: quietFrame, bulbCount: 3, palette: palette, time: 0.1)
        XCTAssertEqual(highOnly[2], highTone(palette.colors[0]),
                       "A treble beat lights the high group without moving the palette on.")
    }

    /// Every color of every shipped palette gives three tones a person can tell apart on
    /// the bulbs, with bass and mid both at full brightness now. A near white palette color
    /// is the one the highlight could flatten, and two near identical palette neighbors,
    /// Blacklight's first two, are the ones the bass tone could.
    func testEveryPaletteColorGivesThreeTonesThatReadApart() {
        for palette in Palette.all {
            for (index, color) in palette.colors.enumerated() {
                var effect = SpreadEffect()
                let colors = room(of: palette, at: index, effect: &effect)
                XCTAssertEqual(colors[0], SpreadEffect.bassTone(at: index, in: palette))
                XCTAssertEqual(colors[1], midTone(color))
                XCTAssertEqual(colors[2], highTone(color))
                let place = "\(palette.name) color \(index)"
                let mid = colors[1].luminance
                let high = colors[2].luminance
                XCTAssertLessThan(mid, high, "\(place): the high group is not lighter.")
                // The full step, or everything the headroom to white allows.
                let expected = min(SpreadEffect.minimumHighlightStep, 255 - mid)
                XCTAssertGreaterThanOrEqual(high - mid, expected - 1,
                                            "\(place): the highlight is too slight to see.")
                for (first, second, names) in [(colors[0], colors[1], "bass and mid"),
                                               (colors[0], colors[2], "bass and high")] {
                    XCTAssertGreaterThanOrEqual(first.channelDistance(to: second),
                                                SpreadEffect.minimumBassStep,
                                                "\(place): \(names) render as the same color.")
                }
            }
        }
    }

    /// The Rec. 601 luma and hue separation Phil's full brightness bass needs: bass is the
    /// deeper shade wherever the palette has a darker color in the same part of the color
    /// wheel to lean toward, and it never leaves the mid group's hue family.
    func testTheBassToneIsADeeperShadeInTheSameHueFamily() {
        var deeper = 0
        var total = 0
        for palette in Palette.all {
            for (index, color) in palette.colors.enumerated() {
                let bass = SpreadEffect.bassTone(at: index, in: palette)
                let place = "\(palette.name) color \(index)"
                total += 1
                XCTAssertLessThanOrEqual(bass.hueDistance(to: color), 45,
                                         "\(place): the bass tone left the hue family.")
                // A palette color that is darker, in the same part of the color wheel, and
                // far enough away that half a lean clears the minimum step.
                let darkerNearby = palette.colors.contains { other in
                    other.luminance < color.luminance
                        && other.hueDistance(to: color) <= SpreadEffect.maximumBassHueDistance
                        && Double(other.channelDistance(to: color)) * SpreadEffect.maximumBassAmount
                            >= Double(SpreadEffect.minimumBassStep)
                }
                if darkerNearby {
                    XCTAssertLessThan(bass.luminance, color.luminance,
                                      "\(place): a darker neighbor exists and bass is not deeper.")
                    deeper += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(deeper, total * 2 / 3,
                                    "Most palette colors should give a deeper bass.")
    }

    /// The bass tone is a blend toward another palette color, 40 to 50 percent of the way,
    /// never a scaled down copy: colors carry hue and the intensity carries brightness.
    func testTheBassToneLeansTowardAnotherPaletteColorAndIsNeverScaled() {
        for palette in Palette.all {
            for (index, color) in palette.colors.enumerated() {
                let bass = SpreadEffect.bassTone(at: index, in: palette)
                let found = palette.colors.enumerated().contains { other, target in
                    other != index && stride(from: 0.4, through: 0.5, by: 0.0005).contains {
                        color.blended(with: target, amount: $0) == bass
                    }
                }
                XCTAssertTrue(found, "\(palette.name) color \(index): \(bass) is not a 40 to 50 "
                              + "percent lean toward another palette color.")
            }
        }
    }

    /// Worked values, so the rule cannot drift unnoticed. Blacklight's first two colors
    /// are nearly the same violet, so both lean to the palette's deep indigo; Party's red
    /// is the darkest thing in its corner of the wheel and leans toward the orange beside
    /// it instead; Fire's amber leans toward the orange below it.
    func testWorkedBassTones() {
        XCTAssertEqual(SpreadEffect.bassTone(at: 1, in: .blacklight), RGB(hex: 0x5500E7))
        XCTAssertEqual(SpreadEffect.bassTone(at: 0, in: .blacklight), RGB(hex: 0x4C00E7))
        XCTAssertEqual(SpreadEffect.bassTone(at: 0, in: .party), RGB(hex: 0xFF3C29))
        XCTAssertEqual(SpreadEffect.bassTone(at: 2, in: .fire), RGB(hex: 0xFF8A00))
        XCTAssertEqual(SpreadEffect.bassTone(at: 3, in: .party), RGB(hex: 0x4699FF))
    }

    /// A one color palette has no neighbor to lean toward, so its bass leans toward the
    /// fully saturated version of the same hue instead: deeper, never dimmer.
    func testAOneColorPalettesBassIsTheSaturatedShade() {
        let single = Palette(id: "one", name: "One",
                             colors: [RGB(hex: 0x3060C0)], dimBase: RGB(hex: 0x050505))
        XCTAssertEqual(SpreadEffect.bassTone(at: 0, in: single), RGB(hex: 0x1850C0))
    }

    /// The contract with the engine: an effect reports hues at full strength and lets the
    /// intensity carry the brightness. Every group reports the whole hit, bass included,
    /// and none of them carries a dimmed color.
    func testNoGroupEverReportsADimmedColor() {
        var effect = SpreadEffect()
        let outputs = effect.tick(beats: allThree,
                                  frame: quietFrame,
                                  bulbCount: 3,
                                  palette: palette,
                                  time: 0)
        let base = palette.colors[0]
        XCTAssertEqual(outputs[0].color, SpreadEffect.bassTone(at: 0, in: palette),
                       "The bass group carries its deeper tone.")
        XCTAssertNotEqual(outputs[0].color, base)
        XCTAssertEqual(outputs[1].color, base)
        XCTAssertGreaterThanOrEqual(outputs[2].color.luminance, base.luminance,
                                    "The high group's hue is lighter, never darker.")

        XCTAssertEqual(outputs[0].intensity, 1, accuracy: 0.0001,
                       "Bass reaches full brightness, the same as the other two groups.")
        XCTAssertEqual(outputs[1].intensity, 1, accuracy: 0.0001)
        XCTAssertEqual(outputs[2].intensity, 1, accuracy: 0.0001)
    }

    /// The bass group has to stay above the floor of a lit room. With Darkest at 30
    /// percent a bass bulb on a beat must be brighter than a calm one, not dimmer.
    func testTheBassGroupStillClearsALitRoomsFloor() {
        var effect = SpreadEffect()
        let outputs = effect.tick(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                  frame: quietFrame,
                                  bulbCount: 3,
                                  palette: palette,
                                  time: 0)
        let calm = outputs[1].calm.rendered(floor: 0.3, ceiling: 1)
        let bass = outputs[0].rendered(floor: 0.3, ceiling: 1)
        XCTAssertGreaterThan(bass.luminance, calm.luminance)
    }

    // MARK: Band assignment
    //
    // Which part of the music a bulb follows is the user's choice. Everything below is
    // about that choice: that an explicit one is obeyed, that no choice at all still
    // behaves exactly as Spread always did, and that a partial one fills itself in.

    func testEveryGroupKnowsItsNameAndItsBands() {
        XCTAssertEqual(SpreadGroup.allCases, [.bass, .mid, .high])
        XCTAssertEqual(SpreadGroup.allCases.map(\.displayName), ["Bass", "Mid", "High"])
        XCTAssertEqual(SpreadGroup.bass.bands, Band.lowBands)
        XCTAssertEqual(SpreadGroup.mid.bands, [.lowMid, .mid])
        XCTAssertEqual(SpreadGroup.high.bands, [.highMid])
        // The raw values are what the app persists, so they are part of the contract.
        XCTAssertEqual(SpreadGroup.allCases.map(\.rawValue), [0, 1, 2])
    }

    func testRoundRobinDealsBulbsBassMidHighInTurn() {
        XCTAssertEqual(SpreadEffect.roundRobin(count: 7),
                       [.bass, .mid, .high, .bass, .mid, .high, .bass])
        XCTAssertEqual(SpreadEffect.roundRobin(count: 0), [])
        XCTAssertEqual(SpreadEffect.roundRobin(count: -3), [])
    }

    /// The point of the feature: the bulbs the user put on Bass are the ones a kick
    /// lights, whatever order they happen to sit in.
    func testAnExplicitAssignmentLightsTheBulbsItNamesOnABassBeat() {
        var effect = SpreadEffect()
        effect.setAssignment([.high, .bass, .bass, .high])
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 4,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[1], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[2], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[0], palette.dimBase)
        XCTAssertEqual(colors[3], palette.dimBase)
    }

    func testAnExplicitAssignmentLightsTheBulbsItNamesOnAHighBeat() {
        var effect = SpreadEffect()
        effect.setAssignment([.high, .bass, .bass, .high])
        let colors = effect.tickColors(beats: [BeatEvent(band: .highMid, time: 0, energy: 0.8)],
                                       frame: quietFrame,
                                       bulbCount: 4,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[0], highTone(palette.colors[0]))
        XCTAssertEqual(colors[3], highTone(palette.colors[0]))
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], palette.dimBase)
    }

    /// Every bulb in a group is one group, so two bulbs on High are the same shade at
    /// the same moment rather than two slightly different ones.
    func testEveryBulbInAGroupRendersIdentically() {
        var effect = SpreadEffect()
        effect.setAssignment([.mid, .mid, .mid, .high, .high])
        let outputs = effect.tick(beats: [BeatEvent(band: .mid, time: 0, energy: 0.8),
                                          BeatEvent(band: .highMid, time: 0, energy: 0.7)],
                                  frame: quietFrame,
                                  bulbCount: 5,
                                  palette: palette,
                                  time: 0)
        XCTAssertEqual(outputs[0].color, outputs[1].color)
        XCTAssertEqual(outputs[1].color, outputs[2].color)
        XCTAssertEqual(outputs[0].intensity, outputs[2].intensity, accuracy: 0.0001)
        XCTAssertEqual(outputs[3].color, outputs[4].color)
        XCTAssertEqual(outputs[3].intensity, outputs[4].intensity, accuracy: 0.0001)
    }

    /// No assignment at all has to be exactly what Spread has always done, or every
    /// existing room changes the day this ships.
    func testNoAssignmentRendersExactlyLikeTheRoundRobin() {
        var untouched = SpreadEffect()
        var assigned = SpreadEffect()
        assigned.setAssignment(SpreadEffect.roundRobin(count: 6))
        let beats = [BeatEvent(band: .bass, time: 0, energy: 0.9),
                     BeatEvent(band: .mid, time: 0, energy: 0.8),
                     BeatEvent(band: .highMid, time: 0, energy: 0.7)]
        for step in 0...3 {
            let time = Double(step) / 10
            XCTAssertEqual(untouched.tickColors(beats: beats, frame: quietFrame, bulbCount: 6,
                                                palette: palette, time: time),
                           assigned.tickColors(beats: beats, frame: quietFrame, bulbCount: 6,
                                               palette: palette, time: time),
                           "Tick \(step)")
        }
    }

    /// A stored assignment can be shorter than the room, because a bulb can arrive after
    /// the user last chose. The tail deals itself out the old way rather than going dark.
    func testAShortAssignmentFallsBackForTheTail() {
        var effect = SpreadEffect()
        effect.setAssignment([.high, .high])
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 5,
                                       palette: palette,
                                       time: 0)
        // 0 and 1 were chosen as High. 2, 3 and 4 fall back to high, bass, mid.
        XCTAssertEqual(colors[0], palette.dimBase)
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], palette.dimBase)
        XCTAssertEqual(colors[3], bassLit(palette.colors[0]), "The tail falls back.")
        XCTAssertEqual(colors[4], palette.dimBase)
    }

    /// The other direction: a bulb that has gone away leaves an assignment longer than
    /// the room, and the extra entries are simply not drawn.
    func testALongerAssignmentIsTruncatedToTheRoom() {
        var effect = SpreadEffect()
        effect.setAssignment([.bass, .high, .bass, .mid, .mid, .high])
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(colors[0], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], bassLit(palette.colors[0]))
    }

    /// Phil's room, if he wants every bulb on the kick.
    func testAnAllBassRoomLightsEveryBulbOnAKick() {
        var effect = SpreadEffect()
        effect.setAssignment(Array(repeating: .bass, count: 6))
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 6,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors, Array(repeating: bassLit(palette.colors[0]), count: 6))
    }

    /// An empty assignment is how "I have chosen nothing" is said, so it has to put the
    /// round robin back rather than leaving the last choice in place.
    func testAnEmptyAssignmentGoesBackToTheRoundRobin() {
        var effect = SpreadEffect()
        effect.setAssignment(Array(repeating: .bass, count: 3))
        effect.setAssignment([])
        XCTAssertEqual(effect.assignment, [])
        let colors = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors[0], bassLit(palette.colors[0]))
        XCTAssertEqual(colors[1], palette.dimBase)
        XCTAssertEqual(colors[2], palette.dimBase)
    }

    /// `reset` is what a resume runs, and a resume must not throw the user's choice away.
    func testResetKeepsTheAssignment() {
        var effect = SpreadEffect()
        effect.setAssignment([.high, .high, .high])
        _ = effect.tickColors(beats: [BeatEvent(band: .highMid, time: 0, energy: 0.8)],
                              frame: quietFrame, bulbCount: 3, palette: palette, time: 0)
        effect.reset()
        XCTAssertEqual(effect.assignment, [.high, .high, .high])
        let colors = effect.tickColors(beats: [BeatEvent(band: .highMid, time: 0, energy: 0.8)],
                                       frame: quietFrame,
                                       bulbCount: 3,
                                       palette: palette,
                                       time: 0)
        XCTAssertEqual(colors, Array(repeating: highTone(palette.colors[0]), count: 3))
    }

    /// The palette still moves on bass beats and nothing else, whoever is listening to
    /// the bass. A room with no bulb on Bass still changes hue on a kick.
    func testThePaletteStillMovesOnBassBeatsInAnAllHighRoom() {
        var effect = SpreadEffect()
        effect.setAssignment(Array(repeating: .high, count: 3))
        let first = effect.tickColors(beats: allThree, frame: quietFrame, bulbCount: 3,
                                      palette: palette, time: 0)
        XCTAssertEqual(first[0], highTone(palette.colors[0]))

        var walked = SpreadEffect()
        walked.setAssignment(Array(repeating: .high, count: 3))
        let second = room(of: palette, at: 1, effect: &walked)
        XCTAssertEqual(second[0], highTone(palette.colors[1]))
    }

    // MARK: Confetti

    /// "Each bulb's own color, with its group's shading": every bulb carries its own
    /// palette color, shaded for the group it follows, and no two neighbors match.
    func testConfettiGivesEachBulbItsOwnColorInItsGroupsShade() {
        var effect = SpreadEffect()
        effect.setConfetti(true)
        let outputs = effect.tick(beats: allThree, frame: quietFrame, bulbCount: 9,
                                  palette: palette, time: 0)
        for (index, output) in outputs.enumerated() {
            let group = SpreadEffect.roundRobin(count: 9)[index]
            let shades: [RGB] = palette.colors.indices.map { position in
                switch group {
                case .bass: return SpreadEffect.bassTone(at: position, in: palette)
                case .mid: return palette.colors[position]
                case .high: return highTone(palette.colors[position])
                }
            }
            XCTAssertTrue(shades.contains(output.color),
                          "Bulb \(index) is not a \(group.displayName) shade of a palette color.")
            XCTAssertEqual(output.intensity, 1, accuracy: 0.0001)
            if index > 0 {
                XCTAssertNotEqual(output.color, outputs[index - 1].color,
                                  "Bulbs \(index - 1) and \(index) match.")
            }
        }
    }

    /// Why confetti Spread can never put two matching colors side by side: neighbors always
    /// sit on different palette colors, and no shade of one palette color is any shade of
    /// another, on any shipped palette.
    func testNoShadeOfOnePaletteColorIsAShadeOfAnother() {
        for palette in Palette.all {
            var seen: [RGB: Int] = [:]
            for position in palette.colors.indices {
                let shades = [SpreadEffect.bassTone(at: position, in: palette),
                              palette.colors[position],
                              highTone(palette.colors[position])]
                for shade in Set(shades) {
                    if let other = seen[shade], other != position {
                        XCTFail("\(palette.name): colors \(other) and \(position) share \(shade).")
                    }
                    seen[shade] = position
                }
            }
        }
    }

    /// Two bulbs on the same band are no longer one color under confetti: each keeps its
    /// own palette color, in the band's shade.
    func testConfettiSplitsABandIntoItsOwnColors() {
        var effect = SpreadEffect()
        effect.setConfetti(true)
        effect.setAssignment(Array(repeating: .mid, count: 6))
        let outputs = effect.tick(beats: allThree, frame: quietFrame, bulbCount: 6,
                                  palette: palette, time: 0)
        XCTAssertTrue(outputs.allSatisfy { palette.colors.contains($0.color) })
        XCTAssertGreaterThan(Set(outputs.map(\.color)).count, 1)
    }

    func testResetReturnsEveryGroupToTheDimBase() {
        var effect = SpreadEffect()
        _ = effect.tickColors(beats: [BeatEvent(band: .bass, time: 0, energy: 0.9),
                                      BeatEvent(band: .highMid, time: 0, energy: 0.8)],
                              frame: quietFrame, bulbCount: 3, palette: palette, time: 0)
        effect.reset()
        let colors = effect.tickColors(beats: [], frame: quietFrame, bulbCount: 3,
                                       palette: palette, time: 0.125)
        XCTAssertEqual(colors, Array(repeating: palette.dimBase, count: 3))
    }
}
