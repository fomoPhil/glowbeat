import Effects
import SwiftUI
import XCTest
@testable import Glowbeat

final class ColorConversionTests: XCTestCase {

    func testAColorRoundTripsThroughSwiftUI() {
        let original = Effects.RGB(r: 200, g: 120, b: 40)
        let converted = ColorConversion.effectsRGB(from: Color(effectsRGB: original))
        XCTAssertLessThanOrEqual(abs(Int(converted.r) - 200), 1)
        XCTAssertLessThanOrEqual(abs(Int(converted.g) - 120), 1)
        XCTAssertLessThanOrEqual(abs(Int(converted.b) - 40), 1)
    }

    func testBlackAndWhiteSurviveTheRoundTrip() {
        XCTAssertEqual(ColorConversion.effectsRGB(from: Color(effectsRGB: .black)), .black)
        let white = Effects.RGB(r: 255, g: 255, b: 255)
        XCTAssertEqual(ColorConversion.effectsRGB(from: Color(effectsRGB: white)), white)
    }

    func testEveryPaletteColorRoundTripsExactly() {
        XCTAssertFalse(Palette.all.isEmpty)
        for palette in Palette.all {
            let colors = palette.colors + [palette.dimBase]
            XCTAssertFalse(colors.isEmpty)
            for color in colors {
                let converted = ColorConversion.effectsRGB(from: Color(effectsRGB: color))
                XCTAssertEqual(converted, color,
                               "\(palette.name) lost \(color) in the round trip")
            }
        }
    }

    /// `BulbRow` drops a color change whose value equals the `Color` its last sync wrote
    /// into the well, so that comparison has to hold for two separately built colors.
    func testTwoColorsBuiltFromTheSameChannelsAreEqual() {
        let color = Effects.RGB(r: 12, g: 200, b: 77)
        XCTAssertEqual(Color(effectsRGB: color), Color(effectsRGB: color))
        XCTAssertNotEqual(Color(effectsRGB: color), Color(effectsRGB: .black))
    }

    // MARK: Level meter peak

    func testThePeakMarkerRisesImmediatelyOnALouderLevel() {
        XCTAssertEqual(LevelMeter.nextPeak(current: 0.8, previous: 0.2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.nextPeak(current: 0.3, previous: 0.3), 0.3, accuracy: 0.0001)
    }

    func testThePeakMarkerDecaysOnSilenceAndReachesZero() {
        let oneStep = LevelMeter.nextPeak(current: 0, previous: 0.5)
        XCTAssertEqual(oneStep, 0.5 - LevelMeter.decayPerTick, accuracy: 0.0001)
        XCTAssertLessThan(oneStep, 0.5)

        var peak = 1.0
        for _ in 0..<Int(LevelMeter.ticksPerSecond * 10) {
            peak = LevelMeter.nextPeak(current: 0, previous: peak)
        }
        XCTAssertEqual(peak, 0, accuracy: 0.0001)
    }

    func testThePeakMarkerNeverFallsBelowTheLiveLevelOrOutsideZeroToOne() {
        XCTAssertEqual(LevelMeter.nextPeak(current: 0.5, previous: 0.505), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.nextPeak(current: 2, previous: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.nextPeak(current: -1, previous: 0.1),
                       0.1 - LevelMeter.decayPerTick, accuracy: 0.0001)
    }

    func testTheGateMarkerMapsADragAcrossTheBarToZeroThroughOne() {
        XCTAssertEqual(LevelMeter.gate(atX: 0, width: 200), 0, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.gate(atX: 100, width: 200), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.gate(atX: 200, width: 200), 1, accuracy: 0.0001)
        // A drag that leaves the bar pins to the end it left by.
        XCTAssertEqual(LevelMeter.gate(atX: -40, width: 200), 0, accuracy: 0.0001)
        XCTAssertEqual(LevelMeter.gate(atX: 400, width: 200), 1, accuracy: 0.0001)
        // A bar with no width yet must not divide by zero.
        XCTAssertEqual(LevelMeter.gate(atX: 10, width: 0), 0, accuracy: 0.0001)
    }

    func testAControlKeepsItsValueUntilTheSettleWindowPasses() {
        let changedAt = Date()
        XCTAssertTrue(ControlSettle.isSettling(since: changedAt, now: changedAt))
        XCTAssertTrue(ControlSettle.isSettling(since: changedAt,
                                               now: changedAt.addingTimeInterval(ControlSettle.duration - 0.5)))
        XCTAssertFalse(ControlSettle.isSettling(since: changedAt,
                                                now: changedAt.addingTimeInterval(ControlSettle.duration)))
        XCTAssertFalse(ControlSettle.isSettling(since: nil, now: changedAt))
    }

    func testAColorFromAnotherColorSpaceStillConverts() {
        // `Color.red` is a system color, not an sRGB literal, so this is the path that
        // needs the explicit conversion before the channels are read.
        let converted = ColorConversion.effectsRGB(from: Color(.displayP3, red: 1, green: 0, blue: 0))
        XCTAssertEqual(converted.r, 255)
        XCTAssertLessThanOrEqual(Int(converted.g), 40)
        XCTAssertLessThanOrEqual(Int(converted.b), 40)
    }

    func testTheColorTemperatureSliderStaysInsideTheHardwareRange() {
        XCTAssertEqual(ColorTemperatureRange.clamp(1000), ColorTemperatureRange.minimum)
        XCTAssertEqual(ColorTemperatureRange.clamp(9000), ColorTemperatureRange.maximum)
        XCTAssertEqual(ColorTemperatureRange.clamp(4000), 4000)
        XCTAssertEqual(ColorTemperatureRange.bounds.lowerBound, Double(ColorTemperatureRange.minimum))
        XCTAssertEqual(ColorTemperatureRange.bounds.upperBound, Double(ColorTemperatureRange.maximum))
    }
}
