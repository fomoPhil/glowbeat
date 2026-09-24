import XCTest
import Effects
@testable import Glowbeat

/// The glide to calm when the music drops below Trigger Level.
///
/// Phil's call on 2026-09-23: "Glide down when the music drops below Trigger Level" instead
/// of a one tick snap. The investigation measured the snap at up to 48 points of brightness
/// in a single tick on every track; a glide over the user's Fade is the same fall the
/// effect's own decay makes after a hit.
final class GateGlideTests: XCTestCase {

    private let red = RGB(hex: 0xFF0044)
    private let blue = RGB(hex: 0x0044FF)

    private func outputs(_ intensities: [Double]) -> [EffectOutput] {
        intensities.map { EffectOutput(color: red, intensity: $0) }
    }

    func testWhileTheGateIsOpenEveryOutputPassesThrough() {
        var glide = GateGlide()
        let wanted = [EffectOutput(color: red, intensity: 1), EffectOutput(color: blue, intensity: 0.4)]
        XCTAssertEqual(glide.apply(wanted, isOpen: true, release: 1, time: 0), wanted)
        XCTAssertEqual(glide.apply(wanted, isOpen: true, release: 1, time: 0.1), wanted)
    }

    /// The heart of it: shut with the effect still asking for a full hit, the room falls
    /// over the Fade rather than landing on calm in one tick.
    func testClosingGlidesToCalmOverTheFade() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0)
        let first = glide.apply(outputs([1]), isOpen: false, release: 1, time: 0.1)
        XCTAssertEqual(first[0].intensity, 0.9, accuracy: 0.0001)
        let halfway = glide.apply(outputs([1]), isOpen: false, release: 1, time: 0.5)
        XCTAssertEqual(halfway[0].intensity, 0.5, accuracy: 0.0001)
        let calm = glide.apply(outputs([1]), isOpen: false, release: 1, time: 1.0)
        XCTAssertEqual(calm[0].intensity, 0, accuracy: 0.0001)
        let later = glide.apply(outputs([1]), isOpen: false, release: 1, time: 5)
        XCTAssertEqual(later[0].intensity, 0, accuracy: 0.0001)
    }

    /// No tick falls further than the Fade allows, which is the measurable promise: at
    /// Phil's 0.79 s Fade and 6 updates a second that is about a fifth of the range.
    func testNoTickFallsFasterThanTheFade() {
        var glide = GateGlide()
        let release = 0.786
        _ = glide.apply(outputs([1, 0.7]), isOpen: true, release: release, time: 0)
        var previous = [1.0, 0.7]
        for step in 1...10 {
            let time = Double(step) / 6
            let shown = glide.apply(outputs([1, 0.7]), isOpen: false, release: release, time: time)
            for index in shown.indices {
                XCTAssertLessThanOrEqual(previous[index] - shown[index].intensity,
                                         (1.0 / 6) / release + 0.0001)
                previous[index] = shown[index].intensity
            }
        }
        XCTAssertEqual(previous, [0, 0])
    }

    /// While the gate is shut nothing gets brighter, whatever the effect asks for: a
    /// volume driven effect can still be climbing on its own clock.
    func testNothingRisesWhileTheGateIsShut() {
        var glide = GateGlide()
        _ = glide.apply(outputs([0.3]), isOpen: true, release: 1, time: 0)
        let shown = glide.apply(outputs([1]), isOpen: false, release: 1, time: 0.1)
        XCTAssertEqual(shown[0].intensity, 0.2, accuracy: 0.0001)
    }

    /// The effect's own fall is followed when it is the faster of the two: the glide caps
    /// the room, it never holds it up.
    func testTheEffectsOwnFallWinsWhenItIsFaster() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0)
        let shown = glide.apply(outputs([0.2]), isOpen: false, release: 1, time: 0.1)
        XCTAssertEqual(shown[0].intensity, 0.2, accuracy: 0.0001)
    }

    /// Reopening can snap straight back up: that is the attack, and a hit after a quiet
    /// passage should land at once.
    func testReopeningSnapsStraightBackUp() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0)
        _ = glide.apply(outputs([1]), isOpen: false, release: 1, time: 0.8)
        let reopened = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0.9)
        XCTAssertEqual(reopened[0].intensity, 1, accuracy: 0.0001)
    }

    /// A session that starts below the gate is calm from its first tick: there is nothing
    /// lit to glide down from.
    func testAGateShutFromTheStartIsCalmAtOnce() {
        var glide = GateGlide()
        let shown = glide.apply(outputs([1, 1]), isOpen: false, release: 1, time: 0)
        XCTAssertEqual(shown.map(\.intensity), [0, 0])
    }

    /// The hue is the effect's; only the intensity glides.
    func testTheColorIsLeftAlone() {
        var glide = GateGlide()
        _ = glide.apply([EffectOutput(color: blue, intensity: 1)], isOpen: true, release: 1, time: 0)
        let shown = glide.apply([EffectOutput(color: red, intensity: 1)], isOpen: false,
                                release: 1, time: 0.1)
        XCTAssertEqual(shown[0].color, red)
    }

    /// The cap is the room's, not each bulb's: Wave's highlight keeps traveling along the
    /// room while it fades, rather than being stopped dead because the bulb it moves onto
    /// was dark a tick ago. Capping each bulb on its own history killed the highlight and
    /// dropped Wave from Brightest to Darkest in one tick, the very snap this removes.
    func testATravelingHighlightKeepsMovingWhileTheRoomFades() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1, 0, 0]), isOpen: true, release: 1, time: 0)
        let moved = glide.apply(outputs([0, 0.9, 0]), isOpen: false, release: 1, time: 0.1)
        XCTAssertEqual(moved[0].intensity, 0, accuracy: 0.0001)
        XCTAssertEqual(moved[1].intensity, 0.9, accuracy: 0.0001, "The highlight moved on.")
        XCTAssertEqual(moved[2].intensity, 0, accuracy: 0.0001)
        let further = glide.apply(outputs([0, 0, 0.8]), isOpen: false, release: 1, time: 0.2)
        XCTAssertEqual(further[2].intensity, 0.8, accuracy: 0.0001)
    }

    /// A bulb arriving while the gate is shut joins the room where the room is: it is
    /// capped by the same falling line, not left dark or lit above it.
    func testABulbArrivingWhileShutFollowsTheRoom() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0)
        let shown = glide.apply(outputs([1, 1]), isOpen: false, release: 1, time: 0.1)
        XCTAssertEqual(shown[0].intensity, 0.9, accuracy: 0.0001)
        XCTAssertEqual(shown[1].intensity, 0.9, accuracy: 0.0001)
    }

    /// A long gap between two ticks, a stopped session or a paused one, has already let
    /// the room settle, so nothing lit is carried across it.
    func testALongGapHasAlreadySettled() {
        var glide = GateGlide()
        _ = glide.apply(outputs([1]), isOpen: true, release: 1, time: 0)
        let shown = glide.apply(outputs([1]), isOpen: false, release: 1, time: 600)
        XCTAssertEqual(shown[0].intensity, 0, accuracy: 0.0001)
    }
}
