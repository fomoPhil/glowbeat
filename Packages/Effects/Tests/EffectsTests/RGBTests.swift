import XCTest
@testable import Effects

final class RGBTests: XCTestCase {

    func testHexInitReadsTheThreeChannels() {
        XCTAssertEqual(RGB(hex: 0xFF0044), RGB(r: 255, g: 0, b: 68))
        XCTAssertEqual(RGB(hex: 0x000000), RGB.black)
    }

    func testBlendedAtZeroReturnsTheReceiver() {
        let base = RGB(r: 10, g: 20, b: 30)
        XCTAssertEqual(base.blended(with: RGB(r: 200, g: 200, b: 200), amount: 0), base)
    }

    func testBlendedAtOneReturnsTheOtherColor() {
        let other = RGB(r: 200, g: 100, b: 50)
        XCTAssertEqual(RGB(r: 0, g: 0, b: 0).blended(with: other, amount: 1), other)
    }

    func testBlendedAtOneHalfIsHalfway() {
        let mixed = RGB(r: 0, g: 0, b: 0).blended(with: RGB(r: 100, g: 200, b: 50), amount: 0.5)
        XCTAssertEqual(mixed, RGB(r: 50, g: 100, b: 25))
    }

    func testBlendedClampsTheAmount() {
        let base = RGB(r: 10, g: 10, b: 10)
        let other = RGB(r: 250, g: 250, b: 250)
        XCTAssertEqual(base.blended(with: other, amount: -3), base)
        XCTAssertEqual(base.blended(with: other, amount: 9), other)
    }

    func testScaledDimsEveryChannel() {
        XCTAssertEqual(RGB(r: 200, g: 100, b: 50).scaled(by: 0.5), RGB(r: 100, g: 50, b: 25))
        XCTAssertEqual(RGB(r: 200, g: 100, b: 50).scaled(by: 0), RGB.black)
    }

    func testBandEnergiesPadsAndTruncatesToFive() {
        XCTAssertEqual(BandEnergies([1, 2]).values, [1, 2, 0, 0, 0])
        XCTAssertEqual(BandEnergies([1, 2, 3, 4, 5, 6, 7]).values, [1, 2, 3, 4, 5])
        XCTAssertEqual(BandEnergies.zero.values, [0, 0, 0, 0, 0])
    }

    func testBandEnergiesSubscript() {
        var energies = BandEnergies([0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(energies[.subBass], 0.1)
        XCTAssertEqual(energies[.highMid], 0.5)
        energies[.mid] = 0.9
        XCTAssertEqual(energies.values, [0.1, 0.2, 0.3, 0.9, 0.5])
    }
}
