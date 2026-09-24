import XCTest
@testable import GoveeLAN

final class GoveeRGBSmokeTests: XCTestCase {
    func testChannelDistanceUsesTheLargestChannelDifference() {
        let a = GoveeRGB(r: 10, g: 200, b: 30)
        let b = GoveeRGB(r: 12, g: 150, b: 31)
        XCTAssertEqual(a.channelDistance(to: b), 50)
    }
}
