import XCTest
@testable import Effects

/// The color clock: the beat moves the brightness, the phrase moves the color.
///
/// Phil's call on 2026-09-23: "Color changes every 4 beats and crossfades; brightness still
/// hits on every beat." These tests pin the clock itself; the effect tests pin that Pulse,
/// Spread and Wave follow it.
final class ColorClockTests: XCTestCase {

    private let palette = Palette.party

    /// Ticks the clock through `beats` low beats `spacing` seconds apart, starting at `start`,
    /// and returns the time of the last one.
    @discardableResult
    private func beat(_ clock: inout ColorClock,
                      times beats: Int,
                      every spacing: TimeInterval,
                      from start: TimeInterval = 0,
                      palette: Palette? = nil) -> TimeInterval {
        var time = start
        for number in 0..<beats {
            time = start + Double(number) * spacing
            clock.tick(lowBeat: true, bulbCount: 1, palette: palette ?? self.palette, time: time)
        }
        return time
    }

    func testTheShippedNumbersAreFourBeatsAHoldAndACrossfade() {
        XCTAssertEqual(ColorClock.beatsPerColor, 4)
        XCTAssertEqual(ColorClock.minimumHold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(ColorClock.crossfade, 0.4, accuracy: 0.0001)
        // A change can never land in the middle of the previous one's crossfade.
        XCTAssertGreaterThanOrEqual(ColorClock.minimumHold, ColorClock.crossfade)
    }

    func testTheRoomStartsOnThePalettesFirstColor() {
        var clock = ColorClock()
        clock.tick(lowBeat: false, bulbCount: 1, palette: palette, time: 0)
        XCTAssertEqual(clock.roomBlend(at: 0).color(in: palette), palette.colors[0])
        XCTAssertEqual(clock.changes, 0)
    }

    /// The opening beats all land on the first color, and the fifth moves it on: four beats
    /// on each color.
    func testThePaletteMovesOnAfterFourBeats() {
        var clock = ColorClock()
        beat(&clock, times: 4, every: 0.5)
        XCTAssertEqual(clock.index, 0, "Four beats on the first color.")
        XCTAssertEqual(clock.changes, 0)

        beat(&clock, times: 1, every: 0.5, from: 2.0)
        XCTAssertEqual(clock.index, 1, "The fifth beat moves the palette on.")
        XCTAssertEqual(clock.changes, 1)

        beat(&clock, times: 3, every: 0.5, from: 2.5)
        XCTAssertEqual(clock.index, 1, "Four beats on the second color, counting the one "
                       + "that brought it in.")
        beat(&clock, times: 1, every: 0.5, from: 4.0)
        XCTAssertEqual(clock.index, 2)
    }

    /// A slow track: one beat a second is four seconds a color.
    func testASlowTrackChangesColorEveryFourBeats() {
        var clock = ColorClock()
        var changedAt: [TimeInterval] = []
        for second in 0..<17 {
            let before = clock.changes
            clock.tick(lowBeat: true, bulbCount: 1, palette: palette, time: Double(second))
            if clock.changes > before { changedAt.append(Double(second)) }
        }
        XCTAssertEqual(changedAt, [4, 8, 12, 16])
    }

    /// A fast track cannot outrun the hold: ten beats a second would be a color every 0.4 s
    /// on the beat count alone, and the hold keeps each color up for at least 0.8 s.
    func testAFastTrackCannotOutrunTheMinimumHold() {
        var clock = ColorClock()
        var changedAt: [TimeInterval] = []
        for step in 0..<60 {
            let time = Double(step) * 0.1
            let before = clock.changes
            clock.tick(lowBeat: true, bulbCount: 1, palette: palette, time: time)
            if clock.changes > before { changedAt.append(time) }
        }
        XCTAssertFalse(changedAt.isEmpty)
        for (earlier, later) in zip(changedAt, changedAt.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, ColorClock.minimumHold - 0.0001,
                                        "Two color changes \(later - earlier) s apart.")
        }
        // The first color is held from the first beat too, not from nothing.
        XCTAssertGreaterThanOrEqual(changedAt[0], ColorClock.minimumHold - 0.0001)
        // Six seconds at a change every 0.8 s is seven changes at most.
        XCTAssertLessThanOrEqual(clock.changes, 7)
        XCTAssertGreaterThanOrEqual(clock.changes, 6, "The hold must not stall the clock.")
    }

    /// Ticks with no beat in them never move the color, however long they run.
    func testTicksWithoutBeatsNeverMoveTheColor() {
        var clock = ColorClock()
        for step in 0..<200 {
            clock.tick(lowBeat: false, bulbCount: 1, palette: palette, time: Double(step) * 0.1)
        }
        XCTAssertEqual(clock.index, 0)
        XCTAssertEqual(clock.changes, 0)
    }

    /// The color crossfades over 0.4 s rather than cutting: at the beat that moves it the
    /// room still shows the old color, halfway through it shows the blend, and at 0.4 s it
    /// has arrived.
    func testAChangeCrossfadesOverFourTenthsOfASecond() {
        var clock = ColorClock()
        let changed = beat(&clock, times: 5, every: 0.5)
        XCTAssertEqual(clock.changes, 1)
        let old = palette.colors[0]
        let new = palette.colors[1]

        XCTAssertEqual(clock.roomBlend(at: changed).color(in: palette), old)
        XCTAssertEqual(clock.roomBlend(at: changed + 0.2).color(in: palette),
                       old.blended(with: new, amount: 0.5))
        XCTAssertEqual(clock.roomBlend(at: changed + 0.4).color(in: palette), new)
        XCTAssertEqual(clock.roomBlend(at: changed + 3).color(in: palette), new)
    }

    /// The point of the crossfade: no single tick jumps the whole distance between two
    /// palette colors. At ten ticks a second each step is a quarter of the way.
    func testNoTickJumpsTheWholeWayBetweenTwoColors() {
        var clock = ColorClock()
        var previous: RGB?
        var largest = 0
        for step in 0..<120 {
            let time = Double(step) * 0.1
            clock.tick(lowBeat: step % 3 == 0, bulbCount: 1, palette: palette, time: time)
            let color = clock.roomBlend(at: time).color(in: palette)
            if let previous { largest = max(largest, color.channelDistance(to: previous)) }
            previous = color
        }
        XCTAssertGreaterThan(clock.changes, 2)
        var widest = 0
        for (index, color) in palette.colors.enumerated() {
            widest = max(widest, color.channelDistance(to: palette.colors[(index + 1) % palette.colors.count]))
        }
        XCTAssertLessThanOrEqual(largest, widest / 4 + 1,
                                 "A tick moved the color \(largest) of a \(widest) jump.")
    }

    func testTheClockWrapsAroundThePalette() {
        var clock = ColorClock()
        for step in 0..<((palette.colors.count * 4) + 1) {
            clock.tick(lowBeat: true, bulbCount: 1, palette: palette, time: Double(step))
        }
        XCTAssertEqual(clock.index, 0, "Five colors, four beats each, and round again.")
        XCTAssertEqual(clock.changes, palette.colors.count)
    }

    func testAOneColorPaletteNeverMoves() {
        let one = Palette(id: "one", name: "One", colors: [RGB(hex: 0x3060C0)],
                          dimBase: RGB(hex: 0x050505))
        var clock = ColorClock()
        beat(&clock, times: 20, every: 1, palette: one)
        XCTAssertEqual(clock.changes, 0)
        XCTAssertEqual(clock.roomBlend(at: 20).color(in: one), one.colors[0])
    }

    func testAnEmptyPaletteShowsTheDimBase() {
        let empty = Palette(id: "empty", name: "Empty", colors: [], dimBase: RGB(hex: 0x0A0A0A))
        var clock = ColorClock()
        beat(&clock, times: 10, every: 1, palette: empty)
        XCTAssertEqual(clock.roomBlend(at: 10).color(in: empty), empty.dimBase)
    }

    /// Switching to a shorter palette with the clock past its end reads modulo the new
    /// size rather than falling off the end.
    func testSwitchingToAShorterPaletteIsSafe() {
        var clock = ColorClock()
        beat(&clock, times: 17, every: 1)
        XCTAssertEqual(clock.index, 4)
        let shorter = Palette.warmWhite
        clock.tick(lowBeat: false, bulbCount: 1, palette: shorter, time: 17)
        XCTAssertTrue(shorter.colors.contains(clock.roomBlend(at: 30).color(in: shorter)))
    }

    func testResetStartsTheClockOver() {
        var clock = ColorClock()
        beat(&clock, times: 9, every: 1)
        XCTAssertEqual(clock.index, 2)
        clock.reset()
        XCTAssertEqual(clock.index, 0)
        XCTAssertEqual(clock.roomBlend(at: 100).color(in: palette), palette.colors[0])
        beat(&clock, times: 4, every: 1, from: 100)
        XCTAssertEqual(clock.index, 0, "A reset counts the four beats from zero again.")
    }

    // MARK: Confetti

    /// Every bulb's own palette position this tick, where it is heading.
    private func layout(_ clock: ColorClock, at time: TimeInterval) -> [Int] {
        clock.blends(at: time).map(\.to)
    }

    private func assertNoNeighborsMatch(_ layout: [Int], _ message: String = "",
                                        file: StaticString = #filePath, line: UInt = #line) {
        for index in layout.indices.dropFirst() where layout[index] == layout[index - 1] {
            XCTFail("Bulbs \(index - 1) and \(index) match in \(layout). \(message)",
                    file: file, line: line)
        }
    }

    /// Without confetti every bulb wears the room's color, fading exactly as the room does.
    func testWithoutConfettiEveryBulbWearsTheRoomsColor() {
        var clock = ColorClock(seed: 1)
        for number in 0..<5 {
            clock.tick(lowBeat: true, bulbCount: 4, palette: palette, time: Double(number))
        }
        for time in [4.0, 4.2, 4.4] {
            XCTAssertEqual(clock.blends(at: time), Array(repeating: clock.roomBlend(at: time), count: 4))
        }
    }

    /// Confetti lays the room out with no two neighbors on the same color, on every
    /// shipped palette and every room size.
    func testConfettiLaysTheRoomOutWithNoNeighborsMatching() {
        for palette in Palette.all {
            for count in 2...15 {
                var clock = ColorClock(seed: UInt64(count))
                clock.setConfetti(true)
                clock.tick(lowBeat: false, bulbCount: count, palette: palette, time: 0)
                assertNoNeighborsMatch(layout(clock, at: 0), palette.name)
                XCTAssertEqual(Set(layout(clock, at: 0)).count > 1, true)
            }
        }
    }

    /// The scatter only changes when the clock moves on: three beats in between leave
    /// every bulb where it was, and the fifth beat re-scatters the whole room.
    func testConfettiRescattersOnlyWhenTheClockMoves() {
        var clock = ColorClock(seed: 3)
        clock.setConfetti(true)
        var previous: [Int]?
        var previousChanges = 0
        for step in 0..<48 {
            let time = Double(step) * 0.25
            clock.tick(lowBeat: step % 2 == 0, bulbCount: 8, palette: palette, time: time)
            let now = layout(clock, at: time)
            assertNoNeighborsMatch(now, "tick \(step)")
            if let previous {
                if clock.changes > previousChanges {
                    XCTAssertTrue(zip(previous, now).allSatisfy { $0 != $1 },
                                  "Every bulb moves at a change, tick \(step).")
                } else {
                    XCTAssertEqual(now, previous, "Tick \(step) re-scattered with no change.")
                }
            }
            previous = now
            previousChanges = clock.changes
        }
        XCTAssertGreaterThan(clock.changes, 3)
    }

    /// Each bulb crossfades from its old color to its new one over the same 0.4 s the room
    /// does, all of them together.
    func testEveryBulbCrossfadesToItsNewColor() {
        var clock = ColorClock(seed: 5)
        clock.setConfetti(true)
        for number in 0..<4 {
            clock.tick(lowBeat: true, bulbCount: 6, palette: palette, time: Double(number))
        }
        let before = layout(clock, at: 3)
        clock.tick(lowBeat: true, bulbCount: 6, palette: palette, time: 4)
        XCTAssertEqual(clock.changes, 1)
        let atTheChange = clock.blends(at: 4)
        XCTAssertEqual(atTheChange.map(\.from), before)
        XCTAssertTrue(atTheChange.allSatisfy { $0.progress == 0 })
        XCTAssertTrue(clock.blends(at: 4.2).allSatisfy { $0.progress == 0.5 })
        XCTAssertTrue(clock.blends(at: 4.4).allSatisfy { $0.progress == 1 })
    }

    /// Turning confetti on fades the room apart from its one color, and off fades it back
    /// together, both on the next tick rather than as a cut.
    func testTurningConfettiOnAndOffCrossfades() {
        var clock = ColorClock(seed: 9)
        clock.tick(lowBeat: false, bulbCount: 5, palette: palette, time: 0)
        clock.setConfetti(true)
        XCTAssertTrue(clock.isConfetti)
        clock.tick(lowBeat: false, bulbCount: 5, palette: palette, time: 1)
        let apart = clock.blends(at: 1)
        XCTAssertEqual(apart.map(\.from), Array(repeating: 0, count: 5))
        XCTAssertTrue(apart.allSatisfy { $0.progress == 0 })
        assertNoNeighborsMatch(apart.map(\.to))
        let scattered = apart.map(\.to)

        clock.setConfetti(false)
        clock.tick(lowBeat: false, bulbCount: 5, palette: palette, time: 2)
        let together = clock.blends(at: 2)
        XCTAssertEqual(together.map(\.from), scattered)
        XCTAssertEqual(together.map(\.to), Array(repeating: 0, count: 5))
        XCTAssertTrue(clock.blends(at: 2.4).allSatisfy { $0.progress == 1 })
    }

    /// A toggle that lands in the middle of a fade waits for it to finish, rather than
    /// cutting it short with a jump.
    func testAToggleDuringAFadeWaitsForItToFinish() {
        var clock = ColorClock(seed: 11)
        for number in 0..<5 {
            clock.tick(lowBeat: true, bulbCount: 4, palette: palette, time: Double(number))
        }
        clock.setConfetti(true)
        clock.tick(lowBeat: false, bulbCount: 4, palette: palette, time: 4.1)
        XCTAssertEqual(layout(clock, at: 4.1), Array(repeating: 1, count: 4),
                       "Still fading to the room's new color.")
        clock.tick(lowBeat: false, bulbCount: 4, palette: palette, time: 4.4)
        assertNoNeighborsMatch(layout(clock, at: 4.4))
        XCTAssertEqual(clock.blends(at: 4.4).map(\.from), Array(repeating: 1, count: 4))
    }

    /// A bulb arriving takes its place at once: a new bulb has no old color to fade from.
    func testANewBulbTakesItsPlaceWithoutAFade() {
        var clock = ColorClock(seed: 13)
        clock.setConfetti(true)
        clock.tick(lowBeat: false, bulbCount: 3, palette: palette, time: 0)
        clock.tick(lowBeat: false, bulbCount: 6, palette: palette, time: 1)
        let blends = clock.blends(at: 1)
        XCTAssertEqual(blends.count, 6)
        XCTAssertTrue(blends.allSatisfy { $0.from == $0.to })
        assertNoNeighborsMatch(blends.map(\.to))
    }

    /// A palette with fewer colors is laid out again at once, so no two neighbors end up
    /// on the same color by reading the old layout round the shorter palette.
    func testSwitchingToAShorterPaletteRescatters() {
        for seed in 0..<50 {
            var clock = ColorClock(seed: UInt64(seed))
            clock.setConfetti(true)
            clock.tick(lowBeat: false, bulbCount: 9, palette: .party, time: 0)
            clock.tick(lowBeat: false, bulbCount: 9, palette: .warmWhite, time: 1)
            let now = layout(clock, at: 1).map { $0 % Palette.warmWhite.colors.count }
            assertNoNeighborsMatch(now, "seed \(seed)")
        }
    }

    /// Resetting keeps the choice: a resume must not quietly turn confetti off.
    func testResetKeepsConfetti() {
        var clock = ColorClock(seed: 17)
        clock.setConfetti(true)
        clock.reset()
        XCTAssertTrue(clock.isConfetti)
        clock.tick(lowBeat: false, bulbCount: 6, palette: palette, time: 0)
        assertNoNeighborsMatch(layout(clock, at: 0))
    }

    /// Spread shades each palette color before blending, so a crossfade between two shaded
    /// colors runs from one shade to the other rather than shading a blend.
    func testABlendCanToneEachEndBeforeMixing() {
        let blend = PaletteBlend(from: 0, to: 1, progress: 0.5)
        let toned = blend.color(in: palette) { index in
            palette.colors[index].blended(with: .white, amount: 0.5)
        }
        let expected = palette.colors[0].blended(with: .white, amount: 0.5)
            .blended(with: palette.colors[1].blended(with: .white, amount: 0.5), amount: 0.5)
        XCTAssertEqual(toned, expected)
    }
}
