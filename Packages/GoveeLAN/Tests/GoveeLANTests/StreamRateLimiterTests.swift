import XCTest
@testable import GoveeLAN

final class StreamRateLimiterTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTheFirstSubmissionForABulbSendsImmediately() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        let color = GoveeRGB(r: 1, g: 2, b: 3)
        XCTAssertEqual(limiter.submit(color, for: "a", now: start), color)
    }

    func testASecondSubmissionInsideTheGapIsHeldBack() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        _ = limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "a", now: start)
        let held = limiter.submit(GoveeRGB(r: 2, g: 2, b: 2), for: "a", now: start.addingTimeInterval(0.05))
        XCTAssertNil(held)
    }

    func testTheLatestHeldColorWinsWhenTheGapElapses() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        _ = limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "a", now: start)
        _ = limiter.submit(GoveeRGB(r: 2, g: 2, b: 2), for: "a", now: start.addingTimeInterval(0.02))
        _ = limiter.submit(GoveeRGB(r: 3, g: 3, b: 3), for: "a", now: start.addingTimeInterval(0.04))

        let released = limiter.drain(now: start.addingTimeInterval(0.13))
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released[0].bulbID, "a")
        XCTAssertEqual(released[0].color, GoveeRGB(r: 3, g: 3, b: 3))
    }

    func testDrainReleasesNothingBeforeTheGapElapses() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        _ = limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "a", now: start)
        _ = limiter.submit(GoveeRGB(r: 2, g: 2, b: 2), for: "a", now: start.addingTimeInterval(0.02))
        XCTAssertTrue(limiter.drain(now: start.addingTimeInterval(0.05)).isEmpty)
    }

    func testEachBulbHasItsOwnBudget() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        XCTAssertNotNil(limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "a", now: start))
        XCTAssertNotNil(limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "b", now: start))
    }

    func testResetClearsHeldColorsAndTimestamps() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        _ = limiter.submit(GoveeRGB(r: 1, g: 1, b: 1), for: "a", now: start)
        _ = limiter.submit(GoveeRGB(r: 2, g: 2, b: 2), for: "a", now: start.addingTimeInterval(0.01))
        limiter.reset()
        XCTAssertTrue(limiter.drain(now: start.addingTimeInterval(5)).isEmpty)
        XCTAssertNotNil(limiter.submit(GoveeRGB(r: 3, g: 3, b: 3), for: "a", now: start.addingTimeInterval(0.02)))
    }

    /// Party Mode streams at the top of the supported range unless the user lowers it.
    func testTheDefaultRateIsTenAndSitsInsideTheSupportedRange() {
        XCTAssertEqual(StreamRateLimiter.defaultSendsPerSecond, 10)
        XCTAssertEqual(StreamRateLimiter.defaultSendsPerSecond,
                       StreamRateLimiter.supportedSendsPerSecond.upperBound)
        XCTAssertEqual(StreamRateLimiter.clampSendsPerSecond(
            StreamRateLimiter.defaultSendsPerSecond), StreamRateLimiter.defaultSendsPerSecond)
        XCTAssertEqual(StreamRateLimiter.supportedSendsPerSecond, 2...10)
    }

    // MARK: The room's send budget

    /// Phil's six bulbs at ten a second felt smooth, ten bulbs at ten a second did not
    /// (smoothness investigation H5, 2026-09-23). Sixty `colorwc` a second is the room.
    func testTheRoomBudgetIsSixtyColorsASecond() {
        XCTAssertEqual(StreamRateLimiter.roomBudgetPerSecond, 60)
    }

    /// The per bulb rate is the budget shared out, never more than the user's ceiling.
    func testThePerBulbRateSharesTheRoomBudget() {
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 6), 10)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 10), 6)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 15), 4)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 7), 8)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 12), 5)
        for count in 1...30 {
            let rate = StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: count)
            XCTAssertLessThanOrEqual(rate * count, StreamRateLimiter.roomBudgetPerSecond,
                                     "\(count) bulbs at \(rate) a second is over the budget.")
        }
    }

    /// The Settings slider is a ceiling: a room small enough to afford more still gets
    /// only what the user allowed.
    func testTheUsersCeilingIsHonored() {
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 6, bulbCount: 6), 6)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 6, bulbCount: 10), 6)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 4, bulbCount: 10), 4)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 3, bulbCount: 1), 3)
        // A ceiling from outside the supported range is clamped like every other rate.
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 99, bulbCount: 3), 10)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 0, bulbCount: 3), 2)
    }

    /// Two a second is the slowest that still reads as motion, so a room of more than
    /// thirty bulbs goes over the budget rather than below that.
    func testThePerBulbRateNeverDropsBelowTheSlowestSupportedRate() {
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 30), 2)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 40), 2)
    }

    /// No bulbs is not a division by zero, it is the ceiling.
    func testAnEmptyRoomRunsAtTheCeiling() {
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 10, bulbCount: 0), 10)
        XCTAssertEqual(StreamRateLimiter.perBulbSendsPerSecond(ceiling: 7, bulbCount: 0), 7)
    }

    // MARK: Spreading one tick's sends

    /// Ten datagrams inside ten milliseconds every tick was the other half of H5. Each bulb
    /// gets a fixed slot inside about twenty milliseconds, by its place in the room, so its
    /// own sends stay exactly one tick apart whoever else sent on that tick.
    func testEachBulbHasItsOwnSlotInsideTwentyMilliseconds() {
        XCTAssertEqual(StreamRateLimiter.tickSpread, 0.020, accuracy: 0.000_001)
        let offsets = (0..<10).map { StreamRateLimiter.sendOffset(forSlot: $0, of: 10) }
        for (index, offset) in offsets.enumerated() {
            XCTAssertEqual(offset, Double(index) * 0.002, accuracy: 0.000_001)
        }
        XCTAssertLessThan(offsets.last ?? 1, StreamRateLimiter.tickSpread)

        let six = (0..<6).map { StreamRateLimiter.sendOffset(forSlot: $0, of: 6) }
        XCTAssertEqual(six.first ?? -1, 0)
        XCTAssertEqual(six[1], 0.020 / 6, accuracy: 0.000_001)
        XCTAssertLessThan(six.last ?? 1, StreamRateLimiter.tickSpread)
    }

    /// A lone bulb has nobody to wait for, and a slot outside the room is clamped into it.
    func testAOneBulbRoomSendsAtOnceAndSlotsAreClamped() {
        XCTAssertEqual(StreamRateLimiter.sendOffset(forSlot: 0, of: 1), 0)
        XCTAssertEqual(StreamRateLimiter.sendOffset(forSlot: 0, of: 0), 0)
        XCTAssertEqual(StreamRateLimiter.sendOffset(forSlot: -3, of: 10), 0)
        XCTAssertEqual(StreamRateLimiter.sendOffset(forSlot: 12, of: 10),
                       StreamRateLimiter.sendOffset(forSlot: 9, of: 10), accuracy: 0.000_001)
    }

    /// The engine ticks at exactly the limiter's gap, and every tick carries a little
    /// jitter. Without a tolerance the early half of that jitter holds the tick back,
    /// the next tick supersedes it, and the effect visibly skips bulbs.
    func testTicksAtTheGapWithJitterAreNeverHeld() {
        var limiter = StreamRateLimiter(maxSendsPerSecond: 8)
        let gap = 1.0 / 8.0
        let jitter: [TimeInterval] = [0, 0.01, -0.01]
        var now = start
        XCTAssertNotNil(limiter.submit(GoveeRGB(r: 0, g: 0, b: 0), for: "a", now: now))

        for tick in 1...20 {
            now = now.addingTimeInterval(gap + jitter[tick % jitter.count])
            let sent = limiter.submit(GoveeRGB(r: UInt8(tick), g: 0, b: 0), for: "a", now: now)
            XCTAssertNotNil(sent, "Tick \(tick) was held back, so the effect skips a frame.")
        }
    }
}
