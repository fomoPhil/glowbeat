import XCTest
import AudioTap
import Effects
import GoveeLAN
@testable import Glowbeat

final class FrameBridgeTests: XCTestCase {

    func testAudioFramesConvertFieldForField() {
        let source = AudioTap.AudioFrame(time: 12.5, rms: 0.4, bands: [0.1, 0.2, 0.3, 0.4, 0.5])
        let converted = FrameBridge.effectsFrame(from: source)
        XCTAssertEqual(converted.time, 12.5)
        XCTAssertEqual(converted.rms, 0.4)
        XCTAssertEqual(converted.bands.values, [0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(converted.bands[.highMid], 0.5)
    }

    func testAudioFrameConversionPadsAShortBandArray() {
        let source = AudioTap.AudioFrame(time: 0, rms: 0, bands: [0.9])
        XCTAssertEqual(FrameBridge.effectsFrame(from: source).bands.values, [0.9, 0, 0, 0, 0])
    }

    func testColorsConvertBothWays() {
        let effectsColor = Effects.RGB(r: 12, g: 34, b: 56)
        let goveeColor = FrameBridge.goveeColor(from: effectsColor)
        XCTAssertEqual(goveeColor, GoveeLAN.GoveeRGB(r: 12, g: 34, b: 56))
        XCTAssertEqual(FrameBridge.effectsColor(from: goveeColor), effectsColor)
    }
}
