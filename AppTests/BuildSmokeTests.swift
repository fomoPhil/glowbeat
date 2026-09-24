import XCTest
import AudioTap
import Effects
import GoveeLAN
@testable import Glowbeat

final class BuildSmokeTests: XCTestCase {
    func testTheAppLinksAllThreePackages() {
        XCTAssertEqual(GoveeRGB(r: 1, g: 2, b: 3).r, 1)
        XCTAssertEqual(RGB(r: 1, g: 2, b: 3).g, 2)
        XCTAssertEqual(AudioTapPermission.granted, .granted)
    }
}
