import XCTest
@testable import Effects

final class RGBSmokeTests: XCTestCase {
    func testChannelDistanceUsesTheLargestChannelDifference() {
        let a = RGB(r: 10, g: 200, b: 30)
        let b = RGB(r: 12, g: 150, b: 31)
        XCTAssertEqual(a.channelDistance(to: b), 50)
    }
}
