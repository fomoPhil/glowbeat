import XCTest
@testable import Effects

final class ColorDeduperTests: XCTestCase {

    func testTheFirstColorForAKeyIsAlwaysSent() {
        var deduper = ColorDeduper()
        XCTAssertTrue(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1"))
    }

    func testAnIdenticalColorIsSuppressed() {
        var deduper = ColorDeduper()
        _ = deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1")
        XCTAssertFalse(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1"))
    }

    func testATinyChangeIsSuppressed() {
        var deduper = ColorDeduper(minimumChannelDelta: 6)
        _ = deduper.shouldSend(RGB(r: 100, g: 100, b: 100), for: "bulb-1")
        XCTAssertFalse(deduper.shouldSend(RGB(r: 103, g: 100, b: 97), for: "bulb-1"))
    }

    func testAVisibleChangeIsSent() {
        var deduper = ColorDeduper(minimumChannelDelta: 6)
        _ = deduper.shouldSend(RGB(r: 100, g: 100, b: 100), for: "bulb-1")
        XCTAssertTrue(deduper.shouldSend(RGB(r: 100, g: 120, b: 100), for: "bulb-1"))
    }

    func testSmallChangesDoNotAccumulateIntoASilentDrift() {
        var deduper = ColorDeduper(minimumChannelDelta: 6)
        _ = deduper.shouldSend(RGB(r: 100, g: 100, b: 100), for: "bulb-1")
        XCTAssertFalse(deduper.shouldSend(RGB(r: 103, g: 100, b: 100), for: "bulb-1"))
        // Still measured against the last color actually sent, so the drift is caught.
        XCTAssertTrue(deduper.shouldSend(RGB(r: 107, g: 100, b: 100), for: "bulb-1"))
    }

    func testAZeroDeltaStillSuppressesExactDuplicates() {
        var deduper = ColorDeduper(minimumChannelDelta: 0)
        XCTAssertTrue(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1"))
        XCTAssertFalse(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1"))
        XCTAssertTrue(deduper.shouldSend(RGB(r: 11, g: 10, b: 10), for: "bulb-1"))
    }

    func testKeysAreIndependent() {
        var deduper = ColorDeduper()
        _ = deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1")
        XCTAssertTrue(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-2"))
    }

    func testForgetAndResetMakeTheNextColorSendAgain() {
        var deduper = ColorDeduper()
        _ = deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1")
        deduper.forget("bulb-1")
        XCTAssertTrue(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-1"))

        _ = deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-2")
        deduper.reset()
        XCTAssertTrue(deduper.shouldSend(RGB(r: 10, g: 10, b: 10), for: "bulb-2"))
    }
}
