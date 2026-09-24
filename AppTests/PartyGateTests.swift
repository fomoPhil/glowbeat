import Effects
import XCTest
@testable import Glowbeat

/// The gate decides when the room is loud enough for Party Mode to react. Below it the
/// bulbs sit at the palette dim base, so the flicker a hovering level would cause is
/// worth pinning precisely.
final class PartyGateTests: XCTestCase {

    /// 50 frames a second, the rate the audio tap runs at.
    private let step: TimeInterval = 0.02

    @discardableResult
    private func drive(_ gate: inout PartyGate, rms: Float, seconds: TimeInterval) -> Bool {
        var isOpen = gate.isOpen
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            isOpen = gate.update(rms: rms, elapsed: step)
            elapsed += step
        }
        return isOpen
    }

    func testItStartsClosed() {
        let gate = PartyGate(threshold: 0.15)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.loudness, 0)
    }

    func testAThresholdOfZeroIsAlwaysOpen() {
        var gate = PartyGate(threshold: 0)
        XCTAssertTrue(gate.update(rms: 0, elapsed: step))
    }

    /// Snappy by design: opening is judged on the raw frames, so two of them over the
    /// marker, 40 ms, light the room. Phil's marker at 69 percent used to need the music
    /// to sit over it for about a second before anything happened.
    func testTwoFramesOverTheThresholdOpenTheGateOnTheSpot() {
        var gate = PartyGate(threshold: 0.69)
        XCTAssertFalse(gate.update(rms: 0.75, elapsed: step))
        XCTAssertTrue(gate.update(rms: 0.75, elapsed: step))
        XCTAssertLessThan(gate.loudness, 0.69,
                          "The smoothed level lags behind; the raw frames are what opened it.")
    }

    /// And the reason it is two rather than one: a single frame over the marker is a
    /// system alert, a click or a glitch, not music. Opening on it flashed the whole room
    /// every time the Mac made a noise.
    func testALoneStrayFrameDoesNotOpenTheGate() {
        var gate = PartyGate(threshold: 0.69)
        XCTAssertFalse(gate.update(rms: 1, elapsed: step),
                       "One frame at full scale is not music.")
        XCTAssertFalse(drive(&gate, rms: 0, seconds: 1),
                       "And nothing the alert left behind may open the gate afterwards.")
    }

    /// A tenth of a second hit opens the gate and the user's Fade holds it open for a
    /// moment afterward, then it settles closed on its own.
    func testAShortBurstOpensTheGateAndFadeHoldsItBriefly() {
        var gate = PartyGate(threshold: 0.69, timing: EffectTiming.from(snap: 0.9, fade: 0.45))
        XCTAssertTrue(drive(&gate, rms: 1, seconds: 0.1))
        XCTAssertTrue(drive(&gate, rms: 0, seconds: 0.1), "Still open just after the hit.")
        XCTAssertFalse(drive(&gate, rms: 0, seconds: 3), "Closed once the level has settled.")
    }

    func testAFrameUnderTheThresholdStillDoesNotOpenIt() {
        var gate = PartyGate(threshold: 0.5)
        XCTAssertFalse(drive(&gate, rms: 0.45, seconds: 1))
    }

    /// The point of the hysteresis: a level sitting just under the threshold keeps an
    /// open gate open rather than chattering the bulbs between color and dim base.
    func testAnOpenGateStaysOpenUntilTheLevelFallsBelowTheCloseThreshold() {
        var gate = PartyGate(threshold: 0.5)
        XCTAssertTrue(drive(&gate, rms: 1, seconds: 0.5))

        XCTAssertTrue(drive(&gate, rms: 0.45, seconds: 2),
                      "0.45 is under the open threshold but over the close threshold.")
        XCTAssertFalse(drive(&gate, rms: 0.3, seconds: 2),
                       "0.3 is under the close threshold, so the gate shuts.")
    }

    /// And the other half of the hysteresis: reopening takes the full threshold, not the
    /// lower one it closed at.
    func testAClosedGateNeedsTheFullThresholdToReopen() {
        var gate = PartyGate(threshold: 0.5)
        drive(&gate, rms: 1, seconds: 0.5)
        drive(&gate, rms: 0, seconds: 2)
        XCTAssertFalse(gate.isOpen)

        XCTAssertFalse(drive(&gate, rms: 0.45, seconds: 2),
                       "0.45 clears the close threshold but not the open threshold.")
        XCTAssertTrue(drive(&gate, rms: 0.6, seconds: 2))
    }

    func testTheCloseThresholdIsEightyPercentOfTheOpenThreshold() {
        XCTAssertEqual(PartyGate(threshold: 0.5).closeThreshold, 0.4, accuracy: 0.0001)
        XCTAssertEqual(PartyGate.closeRatio, 0.8, accuracy: 0.0001)
    }

    /// The release is slow so a gap between beats does not shut the gate.
    func testTheLevelFallsSlowlyEnoughToRideOutAShortGap() {
        var gate = PartyGate(threshold: 0.5)
        drive(&gate, rms: 1, seconds: 0.5)
        XCTAssertTrue(drive(&gate, rms: 0, seconds: 0.2),
                      "A 200 ms gap must not shut the gate.")
        XCTAssertFalse(drive(&gate, rms: 0, seconds: 1))
    }

    func testTheThresholdIsClampedToZeroThroughOne() {
        XCTAssertEqual(PartyGate(threshold: 9).threshold, 1)
        XCTAssertEqual(PartyGate(threshold: -9).threshold, 0)
        var gate = PartyGate(threshold: 0.5)
        gate.threshold = 42
        XCTAssertEqual(gate.threshold, 1)
    }

    func testResetClosesTheGateAndClearsTheLevel() {
        var gate = PartyGate(threshold: 0.5)
        drive(&gate, rms: 1, seconds: 0.5)
        XCTAssertTrue(gate.isOpen)
        gate.reset()
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.loudness, 0)
    }
}
