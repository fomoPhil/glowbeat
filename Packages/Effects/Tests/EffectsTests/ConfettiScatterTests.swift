import XCTest
@testable import Effects

/// Confetti: "Every bulb gets its own color from the palette, and never matches its
/// neighbors." Phil, 2026-09-23. These pin the scatter itself; the clock and effect tests
/// pin that every effect uses it.
final class ConfettiScatterTests: XCTestCase {

    /// Every palette size Glowbeat ships (four and five colors) plus the two smallest a
    /// custom palette could have, every room from 2 to 15 bulbs, many seeds.
    func testNoTwoNeighborsEverShareAColor() {
        let sizes = Set(Palette.all.map(\.colors.count)).union([2, 3]).sorted()
        for size in sizes {
            for count in 2...15 {
                for seed in 0..<200 {
                    var generator = SeededGenerator(seed: UInt64(seed))
                    var layout = ConfettiScatter.scatter(count: count, paletteSize: size,
                                                         previous: nil, using: &generator)
                    for _ in 0..<5 {
                        XCTAssertEqual(layout.count, count)
                        XCTAssertTrue(layout.allSatisfy { (0..<size).contains($0) })
                        for index in 1..<count where layout[index] == layout[index - 1] {
                            XCTFail("\(size) colors, \(count) bulbs, seed \(seed): bulbs "
                                    + "\(index - 1) and \(index) match in \(layout)")
                        }
                        layout = ConfettiScatter.scatter(count: count, paletteSize: size,
                                                         previous: layout, using: &generator)
                    }
                }
            }
        }
    }

    /// Each re-scatter moves every bulb to a different color, so a color change is visible
    /// on every bulb, and never swaps two neighbors' colors, which would put them on the
    /// same blend halfway through the crossfade.
    func testARescatterMovesEveryBulbAndNeverSwapsNeighbors() {
        for size in [3, 4, 5] {
            for count in 2...15 {
                for seed in 0..<100 {
                    var generator = SeededGenerator(seed: UInt64(seed))
                    let old = ConfettiScatter.scatter(count: count, paletteSize: size,
                                                      previous: nil, using: &generator)
                    let new = ConfettiScatter.scatter(count: count, paletteSize: size,
                                                      previous: old, using: &generator)
                    for index in 0..<count {
                        XCTAssertNotEqual(new[index], old[index],
                                          "Bulb \(index) kept its color through a change.")
                    }
                    for index in 1..<count {
                        let swapped = new[index] == old[index - 1] && new[index - 1] == old[index]
                        XCTAssertFalse(swapped, "Bulbs \(index - 1) and \(index) swapped colors.")
                    }
                }
            }
        }
    }

    /// "Never matches its neighbors" holds through the crossfade too, not just at rest. Two
    /// fades can cross: Blacklight's violets sit almost on one line in RGB, so one bulb
    /// fading up it while its neighbor fades down it pass through the same color halfway.
    /// Read at every hundredth of the fade, on every shipped palette.
    func testNeighborsNeverShareAColorPartWayThroughAChange() {
        for palette in Palette.all {
            let colors = palette.colors
            for count in 2...15 {
                for seed in 0..<30 {
                    var generator = SeededGenerator(seed: UInt64(seed))
                    let old = ConfettiScatter.scatter(count: count, colors: colors,
                                                      previous: nil, using: &generator)
                    let new = ConfettiScatter.scatter(count: count, colors: colors,
                                                      previous: old, using: &generator)
                    for index in 1..<count {
                        for step in 0...100 {
                            let progress = Double(step) / 100
                            let left = colors[old[index - 1]].blended(with: colors[new[index - 1]],
                                                                      amount: progress)
                            let right = colors[old[index]].blended(with: colors[new[index]],
                                                                   amount: progress)
                            if left == right {
                                XCTFail("\(palette.name), \(count) bulbs, seed \(seed): bulbs "
                                        + "\(index - 1) and \(index) meet at \(progress).")
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    func testTheClosestApproachOfTwoFades() {
        let red = RGB(hex: 0xFF0000)
        let blue = RGB(hex: 0x0000FF)
        // Swapping two colors meets exactly halfway.
        XCTAssertEqual(ConfettiScatter.closestApproach(left: (red, blue), right: (blue, red)),
                       0, accuracy: 0.01)
        // Fading side by side never gets closer than they start.
        XCTAssertEqual(ConfettiScatter.closestApproach(left: (red, red), right: (blue, blue)),
                       255, accuracy: 0.01)
    }

    /// Two colors can only alternate, and each change flips which one leads so the room
    /// still visibly changes.
    func testTwoColorsAlternateAndFlipOnEachChange() {
        var generator = SeededGenerator(seed: 7)
        let first = ConfettiScatter.scatter(count: 6, paletteSize: 2, previous: nil,
                                            using: &generator)
        XCTAssertTrue(first == [0, 1, 0, 1, 0, 1] || first == [1, 0, 1, 0, 1, 0])
        let second = ConfettiScatter.scatter(count: 6, paletteSize: 2, previous: first,
                                             using: &generator)
        XCTAssertEqual(second, first.map { 1 - $0 })
    }

    /// With one color there is nothing to scatter, and with no bulbs nothing to lay out.
    func testDegenerateRoomsAndPalettes() {
        var generator = SeededGenerator(seed: 1)
        XCTAssertEqual(ConfettiScatter.scatter(count: 4, paletteSize: 1, previous: nil,
                                               using: &generator), [0, 0, 0, 0])
        XCTAssertEqual(ConfettiScatter.scatter(count: 3, paletteSize: 0, previous: nil,
                                               using: &generator), [0, 0, 0])
        XCTAssertEqual(ConfettiScatter.scatter(count: 0, paletteSize: 5, previous: nil,
                                               using: &generator), [])
        XCTAssertEqual(ConfettiScatter.scatter(count: 1, paletteSize: 5, previous: nil,
                                               using: &generator).count, 1)
    }

    /// Random, but repeatable from a seed, which is what lets every other confetti test
    /// pin exact colors.
    func testTheSameSeedScattersTheSameWay() {
        var one = SeededGenerator(seed: 42)
        var two = SeededGenerator(seed: 42)
        XCTAssertEqual(ConfettiScatter.scatter(count: 10, paletteSize: 5, previous: nil, using: &one),
                       ConfettiScatter.scatter(count: 10, paletteSize: 5, previous: nil, using: &two))
        var layouts = Set<[Int]>()
        for seed in 0..<20 {
            var generator = SeededGenerator(seed: UInt64(seed))
            layouts.insert(ConfettiScatter.scatter(count: 10, paletteSize: 5, previous: nil,
                                                   using: &generator))
        }
        XCTAssertGreaterThan(layouts.count, 15, "Different seeds should scatter differently.")
    }
}
