import XCTest
@testable import Effects

final class LoudnessEnvelopeTests: XCTestCase {

    /// 50 frames a second, the rate the audio tap runs at.
    private let step: TimeInterval = 0.02

    private func drive(_ envelope: inout LoudnessEnvelope,
                       target: Float,
                       seconds: TimeInterval) -> Float {
        var value = envelope.value
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            value = envelope.update(target, elapsed: step)
            elapsed += step
        }
        return value
    }

    func testItStartsAtZero() {
        XCTAssertEqual(LoudnessEnvelope(attack: 0.05, release: 0.3).value, 0)
    }

    /// One time constant covers about 63 percent of the distance, which is what makes
    /// the attack and release times mean something.
    func testOneTimeConstantCoversAboutSixtyThreePercent() {
        var envelope = LoudnessEnvelope(attack: 0.1, release: 0.1)
        let value = drive(&envelope, target: 1, seconds: 0.1)
        XCTAssertEqual(value, 0.63, accuracy: 0.03)
    }

    func testItRisesFasterThanItFalls() {
        var rising = LoudnessEnvelope(attack: 0.05, release: 0.4)
        let afterRise = drive(&rising, target: 1, seconds: 0.1)

        var falling = LoudnessEnvelope(attack: 0.05, release: 0.4)
        _ = drive(&falling, target: 1, seconds: 1)
        let afterFall = drive(&falling, target: 0, seconds: 0.1)

        XCTAssertGreaterThan(afterRise, 0.8, "A 50 ms attack should be most of the way up in 100 ms.")
        XCTAssertGreaterThan(afterFall, 0.6, "A 400 ms release should still be high after 100 ms.")
    }

    func testASustainedLevelIsReached() {
        var envelope = LoudnessEnvelope(attack: 0.05, release: 0.4)
        let value = drive(&envelope, target: 0.42, seconds: 2)
        XCTAssertEqual(value, 0.42, accuracy: 0.001)
    }

    func testAZeroElapsedUpdateDoesNotMove() {
        var envelope = LoudnessEnvelope(attack: 0.05, release: 0.4)
        _ = drive(&envelope, target: 1, seconds: 1)
        let held = envelope.value
        XCTAssertEqual(envelope.update(0, elapsed: 0), held)
        XCTAssertEqual(envelope.update(0, elapsed: -1), held)
    }

    func testTargetsAreClampedToZeroThroughOne() {
        var envelope = LoudnessEnvelope(attack: 0.05, release: 0.4)
        XCTAssertEqual(drive(&envelope, target: 5, seconds: 2), 1, accuracy: 0.001)
        XCTAssertEqual(drive(&envelope, target: -5, seconds: 4), 0, accuracy: 0.001)
    }

    func testResetReturnsToZero() {
        var envelope = LoudnessEnvelope(attack: 0.05, release: 0.4)
        _ = drive(&envelope, target: 1, seconds: 1)
        envelope.reset()
        XCTAssertEqual(envelope.value, 0)
    }
}
