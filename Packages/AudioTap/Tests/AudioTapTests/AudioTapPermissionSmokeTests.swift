import XCTest
@testable import AudioTap

final class AudioTapPermissionSmokeTests: XCTestCase {
    func testPermissionHasThreeCases() {
        XCTAssertEqual(AudioTapPermission.allCases.count, 3)
        XCTAssertEqual(AudioTapPermission.unknown.rawValue, "unknown")
    }
}
