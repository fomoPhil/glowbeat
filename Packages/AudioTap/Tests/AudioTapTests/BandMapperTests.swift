import XCTest
@testable import AudioTap

final class BandMapperTests: XCTestCase {

    private let sampleRate: Double = 48_000

    private func sine(frequency: Double, seconds: Double, amplitude: Float = 1.0) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func lastFrame(for samples: [Float]) -> AudioFrame? {
        let mapper = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)
        return mapper.process(samples, time: 0).last
    }

    func testASixtyHertzSineLandsInSubBass() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 60, seconds: 1.0)))
        XCTAssertEqual(frame.bands.count, 5)
        let peak = try XCTUnwrap(frame.bands.max())
        XCTAssertEqual(frame.bands[0], peak, accuracy: 0.0001)
        XCTAssertGreaterThan(frame.bands[0], 0.5)
        XCTAssertGreaterThan(frame.bands[0], frame.bands[1])
    }

    func testAThreeKilohertzSineLandsInHighMid() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 3000, seconds: 1.0)))
        let peak = try XCTUnwrap(frame.bands.max())
        XCTAssertEqual(frame.bands[4], peak, accuracy: 0.0001)
        XCTAssertGreaterThan(frame.bands[4], 0.5)
    }

    func testAOneHundredFiftyHertzSineLandsInBass() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 150, seconds: 1.0)))
        let peak = try XCTUnwrap(frame.bands.max())
        XCTAssertEqual(frame.bands[1], peak, accuracy: 0.0001)
    }

    func testAOneKilohertzSineLandsInMid() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 1000, seconds: 1.0)))
        let peak = try XCTUnwrap(frame.bands.max())
        XCTAssertEqual(frame.bands[3], peak, accuracy: 0.0001)
    }

    func testAThreeHundredHertzSineLandsInLowMid() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 300, seconds: 1.0)))
        let peak = try XCTUnwrap(frame.bands.max())
        XCTAssertEqual(frame.bands[2], peak, accuracy: 0.0001)
    }

    func testSilenceProducesZeroBandsAndZeroRMS() throws {
        let silence = [Float](repeating: 0, count: Int(sampleRate))
        let frame = try XCTUnwrap(lastFrame(for: silence))
        XCTAssertEqual(frame.rms, 0, accuracy: 0.0001)
        for value in frame.bands {
            XCTAssertEqual(value, 0, accuracy: 0.0001)
        }
    }

    func testAFullScaleSineProducesAnRMSNearOne() throws {
        let frame = try XCTUnwrap(lastFrame(for: sine(frequency: 1000, seconds: 1.0)))
        XCTAssertGreaterThan(frame.rms, 0.9)
        XCTAssertLessThanOrEqual(frame.rms, 1.0)
    }

    func testAQuieterSineProducesASmallerBandValue() throws {
        let loud = try XCTUnwrap(lastFrame(for: sine(frequency: 1000, seconds: 1.0, amplitude: 1.0)))
        let quiet = try XCTUnwrap(lastFrame(for: sine(frequency: 1000, seconds: 1.0, amplitude: 0.2)))
        XCTAssertGreaterThan(loud.bands[3], quiet.bands[3] * 2)
    }

    func testOneSecondOfAudioProducesAboutFiftyFrames() {
        let mapper = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)
        let frames = mapper.process(sine(frequency: 440, seconds: 1.0), time: 0)
        XCTAssertGreaterThanOrEqual(frames.count, 46)
        XCTAssertLessThanOrEqual(frames.count, 52)
    }

    func testFrameTimestampsAdvanceByTheHopDuration() throws {
        let mapper = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)
        let frames = mapper.process(sine(frequency: 440, seconds: 0.5), time: 10)
        XCTAssertGreaterThan(frames.count, 3)
        let firstGap = frames[1].time - frames[0].time
        XCTAssertEqual(firstGap, 0.02, accuracy: 0.002)
        XCTAssertGreaterThan(frames[0].time, 10)
    }

    func testFeedingInSmallChunksGivesTheSameBandAsOneLargeBuffer() throws {
        let samples = sine(frequency: 3000, seconds: 1.0)
        let single = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)
        let chunked = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)

        let singleFrame = try XCTUnwrap(single.process(samples, time: 0).last)
        var chunkedFrames: [AudioFrame] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + 512)
            chunkedFrames += chunked.process(Array(samples[offset..<end]),
                                             time: Double(offset) / sampleRate)
            offset = end
        }
        let chunkedFrame = try XCTUnwrap(chunkedFrames.last)
        XCTAssertEqual(singleFrame.bands[4], chunkedFrame.bands[4], accuracy: 0.05)
    }

    func testBandBinsAreOrderedAndDisjointAtEverySupportedSampleRate() {
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0] {
            let bins = BandMapper(sampleRate: rate).bandBins
            XCTAssertEqual(bins.count, 5, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(bins[0].lowerBound, 1, "rate \(rate)")
            for index in 1..<bins.count {
                XCTAssertGreaterThan(bins[index].lowerBound,
                                     bins[index - 1].upperBound,
                                     "bands \(index - 1) and \(index) overlap at \(rate)")
            }
        }
    }

    func testResetClearsTheSmoothingState() throws {
        let mapper = BandMapper(sampleRate: sampleRate, framesPerSecond: 50, smoothing: 0.35)
        _ = mapper.process(sine(frequency: 3000, seconds: 1.0), time: 0)
        mapper.reset()
        let frames = mapper.process([Float](repeating: 0, count: 2048), time: 0)
        let frame = try XCTUnwrap(frames.last)
        XCTAssertEqual(frame.bands[4], 0, accuracy: 0.0001)
    }
}
