import XCTest
import GoveeLAN
@testable import Glowbeat

final class ExternalChangeDetectorTests: XCTestCase {

    private let detector = ExternalChangeDetector()

    private func state(on: Bool = true,
                       brightness: Int = 80,
                       color: GoveeRGB = GoveeRGB(r: 100, g: 100, b: 100)) -> BulbState {
        BulbState(isOn: on, brightness: brightness, color: color, colorTemperatureKelvin: 0)
    }

    func testNoFindingWhenEverythingMatches() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 100, g: 100, b: 100)])
        XCTAssertEqual(detector.evaluate(reported: state(), expectation: expectation), .none)
    }

    func testPowerChangeIsExternal() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 100, g: 100, b: 100)])
        XCTAssertEqual(detector.evaluate(reported: state(on: false), expectation: expectation),
                       .power)
    }

    func testBrightnessChangeIsExternal() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 100, g: 100, b: 100)])
        XCTAssertEqual(detector.evaluate(reported: state(brightness: 30),
                                         expectation: expectation),
                       .brightness)
    }

    func testAColorInsideTheToleranceOfAnyRecentColorIsNotExternal() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 10, g: 10, b: 10),
                           GoveeRGB(r: 200, g: 0, b: 0),
                           GoveeRGB(r: 0, g: 200, b: 0)])
        // Seven off the second recent color, inside the tolerance of eight.
        let reported = state(color: GoveeRGB(r: 193, g: 7, b: 0))
        XCTAssertEqual(detector.evaluate(reported: reported, expectation: expectation), .none)
    }

    func testAColorMatchingNoRecentColorIsExternal() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 200, g: 0, b: 0), GoveeRGB(r: 0, g: 200, b: 0)])
        let reported = state(color: GoveeRGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(detector.evaluate(reported: reported, expectation: expectation), .color)
    }

    // MARK: The firmware fade (Phil's false takeover, 2026-09-23)
    //
    // An H6004 does not jump to a `colorwc` color, it fades there, so a status poll can
    // land part way along the straight line from one sent color to the next.

    private func expecting(_ colors: [GoveeRGB]) -> ExternalChangeDetector.Expectation {
        ExternalChangeDetector.Expectation(expectedPower: true,
                                           expectedBrightness: 80,
                                           recentColors: colors)
    }

    func testAColorHalfWayAlongTheFadeBetweenTwoSentColorsIsNotExternal() {
        let expectation = expecting([GoveeRGB(r: 200, g: 0, b: 0), GoveeRGB(r: 0, g: 0, b: 200)])
        // A hundred from both ends on two channels, and exactly on the line between them.
        let reported = state(color: GoveeRGB(r: 100, g: 0, b: 100))
        XCTAssertEqual(detector.evaluate(reported: reported, expectation: expectation), .none)
    }

    func testTheFadeGetsTheSameEightPerChannelSlackAsASentColor() {
        let expectation = expecting([GoveeRGB(r: 200, g: 0, b: 0), GoveeRGB(r: 0, g: 0, b: 200)])
        XCTAssertEqual(detector.evaluate(reported: state(color: GoveeRGB(r: 100, g: 8, b: 100)),
                                         expectation: expectation),
                       .none)
        XCTAssertEqual(detector.evaluate(reported: state(color: GoveeRGB(r: 100, g: 9, b: 100)),
                                         expectation: expectation),
                       .color)
    }

    /// The bulb fades from each color to the one sent after it, never from the first
    /// straight to the third.
    func testOnlyConsecutiveSentColorsMakeAFade() {
        let expectation = expecting([GoveeRGB(r: 200, g: 0, b: 0),
                                     GoveeRGB(r: 0, g: 200, b: 0),
                                     GoveeRGB(r: 0, g: 0, b: 200)])
        let halfWayFromFirstToThird = state(color: GoveeRGB(r: 100, g: 0, b: 100))
        XCTAssertEqual(detector.evaluate(reported: halfWayFromFirstToThird, expectation: expectation),
                       .color)
    }

    /// A fade stops at the color it was heading for; it is a segment, not a line.
    func testAColorPastTheEndOfAFadeIsExternal() {
        let expectation = expecting([GoveeRGB(r: 100, g: 0, b: 0), GoveeRGB(r: 200, g: 0, b: 0)])
        XCTAssertEqual(detector.evaluate(reported: state(color: GoveeRGB(r: 240, g: 0, b: 0)),
                                         expectation: expectation),
                       .color)
    }

    // MARK: A run of unexplained polls
    //
    // A phone sets one color and leaves it. A bulb that is behind or mid fade reports a
    // different wrong color every time it is asked.

    private func run(_ colors: [GoveeRGB]) -> ExternalChangeDetector.ColorMismatchRun {
        var run = ExternalChangeDetector.ColorMismatchRun()
        for color in colors {
            run.add(color)
        }
        return run
    }

    private let phoneGreen = GoveeRGB(r: 0, g: 200, b: 60)

    func testTwoUnexplainedPollsAreNotYetATakeover() {
        XCTAssertEqual(ExternalChangeDetector.colorPollsBeforePause, 3)
        XCTAssertFalse(run([phoneGreen, phoneGreen]).isTakeover)
    }

    func testThreePollsOfOneSteadyColorAreATakeover() {
        XCTAssertTrue(run([phoneGreen, phoneGreen, phoneGreen]).isTakeover)
    }

    func testASteadyColorMayMoveInsideTheTolerance() {
        let jittered = [GoveeRGB(r: 0, g: 200, b: 60),
                        GoveeRGB(r: 4, g: 196, b: 64),
                        GoveeRGB(r: 8, g: 200, b: 60)]
        XCTAssertTrue(run(jittered).isTakeover)
    }

    func testAColorThatWandersFromPollToPollIsNeverATakeover() {
        let wandering = [GoveeRGB(r: 0, g: 200, b: 60),
                         GoveeRGB(r: 0, g: 90, b: 220),
                         GoveeRGB(r: 30, g: 240, b: 240),
                         GoveeRGB(r: 0, g: 140, b: 120),
                         GoveeRGB(r: 90, g: 0, b: 200),
                         GoveeRGB(r: 200, g: 200, b: 0)]
        var run = ExternalChangeDetector.ColorMismatchRun()
        for color in wandering {
            run.add(color)
            XCTAssertFalse(run.isTakeover, "Pausing on a wandering color, at \(color).")
        }
    }

    /// Every color of a run has to sit with every other, not just with its neighbor, or
    /// a slow creep would count as steady.
    func testASlowCreepWiderThanTheToleranceIsNotSteady() {
        let creeping = [GoveeRGB(r: 0, g: 200, b: 60),
                        GoveeRGB(r: 8, g: 200, b: 60),
                        GoveeRGB(r: 16, g: 200, b: 60)]
        XCTAssertFalse(run(creeping).isTakeover)
    }

    /// When the unexplained color moves, the count starts again from the new color.
    func testARunThatMovesStartsAgainFromTheNewColor() {
        let elsewhere = GoveeRGB(r: 200, g: 0, b: 200)
        XCTAssertFalse(run([phoneGreen, phoneGreen, elsewhere]).isTakeover)
        XCTAssertFalse(run([phoneGreen, phoneGreen, elsewhere, elsewhere]).isTakeover)
        XCTAssertTrue(run([phoneGreen, phoneGreen, elsewhere, elsewhere, elsewhere]).isTakeover)
    }

    func testNilExpectationsNeverTrigger() {
        let expectation = ExternalChangeDetector.Expectation(expectedPower: nil,
                                                            expectedBrightness: nil,
                                                            recentColors: [])
        XCTAssertEqual(detector.evaluate(reported: state(on: false, brightness: 1),
                                         expectation: expectation),
                       .none)
    }

    func testPowerIsCheckedBeforeBrightnessAndColor() {
        let expectation = ExternalChangeDetector.Expectation(
            expectedPower: true,
            expectedBrightness: 80,
            recentColors: [GoveeRGB(r: 200, g: 0, b: 0)])
        let reported = state(on: false, brightness: 5, color: GoveeRGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(detector.evaluate(reported: reported, expectation: expectation), .power)
    }

    // MARK: A brightness Glowbeat just sent

    /// Party Mode sets every bulb to 100 on start. The command is UDP with repeats a
    /// second apart, so a bulb can answer a poll or two still at its old brightness. That
    /// is Glowbeat's own command not landing yet, not a phone.
    func testABrightnessGlowbeatJustSentIsNotJudgedUntilTheBulbShowsIt() {
        var check = ExternalChangeDetector.BrightnessCheck()
        XCTAssertNil(check.expectation(for: "a", reported: 30, sent: 100, baseline: 30))
        XCTAssertNil(check.expectation(for: "a", reported: 30, sent: 100, baseline: 30))
        XCTAssertEqual(check.expectation(for: "a", reported: 100, sent: 100, baseline: 30), 100)
    }

    /// Once the bulb has shown what Glowbeat sent, anything else is someone else's doing.
    func testOnceTheBulbHasShownItAPhoneBrightnessIsJudged() {
        var check = ExternalChangeDetector.BrightnessCheck()
        XCTAssertEqual(check.expectation(for: "a", reported: 100, sent: 100, baseline: 100), 100)
        let expected = check.expectation(for: "a", reported: 40, sent: 100, baseline: 100)
        XCTAssertEqual(expected, 100)
        let judged = detector.evaluate(reported: state(brightness: 40),
                                       expectation: .init(expectedPower: true,
                                                          expectedBrightness: expected,
                                                          recentColors: []))
        XCTAssertEqual(judged, .brightness)
    }

    /// Until then the report is not judged on brightness at all, and power and color are
    /// still judged as they always were.
    func testAnUnshownBrightnessLeavesPowerAndColorToBeJudged() {
        var check = ExternalChangeDetector.BrightnessCheck()
        let expected = check.expectation(for: "a", reported: 30, sent: 100, baseline: 30)
        let off = detector.evaluate(reported: state(on: false, brightness: 30),
                                    expectation: .init(expectedPower: true,
                                                       expectedBrightness: expected,
                                                       recentColors: []))
        XCTAssertEqual(off, .power)
        let lit = detector.evaluate(reported: state(brightness: 30),
                                    expectation: .init(expectedPower: true,
                                                       expectedBrightness: expected,
                                                       recentColors: []))
        XCTAssertEqual(lit, .none)
    }

    /// With no brightness sent this session, the session's first report is the one to
    /// match, exactly as before.
    func testWithNothingSentTheBaselineIsTheExpectation() {
        var check = ExternalChangeDetector.BrightnessCheck()
        XCTAssertEqual(check.expectation(for: "a", reported: 40, sent: nil, baseline: 70), 70)
        XCTAssertNil(check.expectation(for: "a", reported: 40, sent: nil, baseline: nil))
    }

    /// A new brightness from Glowbeat, the All bulbs slider dragged mid session, is its
    /// own command in flight: the bulb has to show it before it is judged against it.
    func testANewlySentBrightnessHasToBeShownAgain() {
        var check = ExternalChangeDetector.BrightnessCheck()
        XCTAssertEqual(check.expectation(for: "a", reported: 100, sent: 100, baseline: 100), 100)
        XCTAssertNil(check.expectation(for: "a", reported: 100, sent: 50, baseline: 100))
        XCTAssertEqual(check.expectation(for: "a", reported: 50, sent: 50, baseline: 100), 50)
    }

    func testEachBulbIsCheckedOnItsOwnAndAResetForgetsThemAll() {
        var check = ExternalChangeDetector.BrightnessCheck()
        XCTAssertEqual(check.expectation(for: "a", reported: 100, sent: 100, baseline: 30), 100)
        XCTAssertNil(check.expectation(for: "b", reported: 30, sent: 100, baseline: 30))
        check.reset()
        XCTAssertNil(check.expectation(for: "a", reported: 30, sent: 100, baseline: 30))
    }

    func testEveryFindingCarriesAUserFacingReasonExceptNone() {
        XCTAssertNil(ExternalChangeDetector.Finding.none.reason)
        for finding in [ExternalChangeDetector.Finding.power, .brightness, .color] {
            let reason = finding.reason
            XCTAssertNotNil(reason)
            XCTAssertFalse(reason?.isEmpty ?? true)
        }
    }
}
