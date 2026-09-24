import XCTest
@testable import Effects

final class PaletteTests: XCTestCase {

    func testThereAreExactlyTenPalettesWithUniqueIDs() {
        XCTAssertEqual(Palette.all.count, 10)
        XCTAssertEqual(Set(Palette.all.map(\.id)).count, 10)
    }

    func testEveryPaletteHasFourToSixColorsAndADarkDimBase() {
        for palette in Palette.all {
            XCTAssertTrue((4...6).contains(palette.colors.count),
                          "\(palette.id) has \(palette.colors.count) colors.")
            let base = palette.dimBase
            let brightness = Int(base.r) + Int(base.g) + Int(base.b)
            XCTAssertLessThan(brightness, 200, "\(palette.id) dim base is not dim.")
        }
    }

    func testPaletteLookupFallsBackToParty() {
        XCTAssertEqual(Palette.palette(withID: "ocean").id, "ocean")
        XCTAssertEqual(Palette.palette(withID: "does-not-exist").id, "party")
    }

    func testPaletteNamesAreSentenceCase() {
        XCTAssertEqual(Palette.warmWhite.name, "Warm white")
        XCTAssertEqual(Palette.party.name, "Party")
        XCTAssertEqual(Palette.blacklight.name, "Blacklight")
        for palette in Palette.all {
            XCTAssertFalse(palette.name.isEmpty)
            let words = palette.name.split(separator: " ").dropFirst()
            for word in words {
                XCTAssertEqual(word.first, word.first?.lowercased().first,
                               "\(palette.id) is not sentence case.")
            }
        }
    }

    /// The five palettes added in v1.2 are looked up by the ids that get persisted, so a
    /// rename that leaves the id behind is caught here rather than by a user whose
    /// choice silently fell back to Party.
    func testTheV12PalettesAreAllReachableByID() {
        let expected = ["blacklight", "forest", "candy", "ice", "fire"]
        for id in expected {
            XCTAssertEqual(Palette.palette(withID: id).id, id)
        }
        XCTAssertEqual(Palette.all.suffix(5).map(\.id), expected)
    }

    func testBlacklightUsesTheApprovedViolets() {
        XCTAssertEqual(Palette.blacklight.colors,
                       [RGB(hex: 0x5A00FF), RGB(hex: 0x6A00FF), RGB(hex: 0x8F00FF),
                        RGB(hex: 0xB400FF), RGB(hex: 0x3A00C8)])
        // Every entry has to read as violet on an RGB bulb, which means red present and
        // blue leading it. A blue with no red in it is just blue.
        for color in Palette.blacklight.colors {
            XCTAssertGreaterThan(color.r, 0, "A blacklight color with no red reads blue.")
            XCTAssertGreaterThan(color.b, color.r)
            XCTAssertEqual(color.g, 0)
        }
        // A faint violet: blue leads, red trails it, and there is no green at all.
        XCTAssertGreaterThan(Palette.blacklight.dimBase.b, Palette.blacklight.dimBase.r)
        XCTAssertEqual(Palette.blacklight.dimBase.g, 0)
    }
}
