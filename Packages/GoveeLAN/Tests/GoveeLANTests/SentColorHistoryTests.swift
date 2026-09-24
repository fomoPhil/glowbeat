import XCTest
@testable import GoveeLAN

/// The send history phone takeover detection reads. Bounded by time rather than by count,
/// because a status poll says what a bulb looked like at a moment, and at ten sends a
/// second a count of five is only half a second of that. Every time here is explicit.
final class SentColorHistoryTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func color(_ index: Int) -> GoveeRGB {
        GoveeRGB(r: UInt8(index % 256), g: UInt8((index * 7) % 256), b: 9)
    }

    /// `count` colors a tenth of a second apart from `start`, the way Party Mode streams.
    private func streamed(_ count: Int,
                          window: TimeInterval = 3,
                          minimumCount: Int = 5) -> SentColorHistory {
        var history = SentColorHistory(window: window, minimumCount: minimumCount)
        for index in 0..<count {
            history.record(color(index), at: start.addingTimeInterval(Double(index) * 0.1))
        }
        return history
    }

    func testNothingSentMeansNothingToMatchAgainst() {
        let history = SentColorHistory(window: 3, minimumCount: 5)
        XCTAssertEqual(history.entries(asOf: start), [])
    }

    /// The lag case from Phil's report: a bulb fifteen sends behind, and a reply half a
    /// second late on top of that, is still reporting a color from inside the window.
    func testAColorSentFifteenSendsAgoIsStillThereForALateReply() {
        let history = streamed(20)
        let lastSend = start.addingTimeInterval(1.9)
        let colors = history.entries(asOf: lastSend.addingTimeInterval(0.5)).map(\.color)
        XCTAssertTrue(colors.contains(color(19 - 15)))
        XCTAssertEqual(colors, (0..<20).map(color))
    }

    func testEntriesKeepTheOrderAndTheTimeTheyWereSent() {
        let history = streamed(3)
        XCTAssertEqual(history.entries(asOf: start.addingTimeInterval(0.2)),
                       [SentColorHistory.Entry(color: color(0), sentAt: start),
                        SentColorHistory.Entry(color: color(1), sentAt: start.addingTimeInterval(0.1)),
                        SentColorHistory.Entry(color: color(2), sentAt: start.addingTimeInterval(0.2))])
    }

    /// Six seconds of Party Mode, asked about at the end: the last three seconds, plus the
    /// one color the bulb was already fading from when those three seconds began.
    func testColorsOlderThanTheWindowFallOutExceptTheOneTheBulbWasHolding() {
        let history = streamed(61)
        let asOf = start.addingTimeInterval(6.0)
        let entries = history.entries(asOf: asOf)
        // Sends 30 (3.0 s) to 60 (6.0 s) are in the window, and send 29 opened it.
        XCTAssertEqual(entries.map(\.color), (29...60).map(color))
        XCTAssertLessThan(entries[0].sentAt, asOf.addingTimeInterval(-3))
        XCTAssertGreaterThanOrEqual(entries[1].sentAt, asOf.addingTimeInterval(-3))
    }

    /// Quiet music sends nothing new, so a bulb holds its last color for as long as the
    /// quiet lasts. That color, and the fade into it, must still count.
    func testTheLastColorSentStillCountsLongAfterTheWindow() {
        var history = SentColorHistory(window: 3, minimumCount: 1)
        history.record(color(1), at: start)
        history.record(color(2), at: start.addingTimeInterval(0.1))
        XCTAssertEqual(history.entries(asOf: start.addingTimeInterval(60)).map(\.color),
                       [color(2)])

        history.record(color(3), at: start.addingTimeInterval(60))
        XCTAssertEqual(history.entries(asOf: start.addingTimeInterval(60.2)).map(\.color),
                       [color(2), color(3)],
                       "The fade from the held color into the new one starts at the held color.")
    }

    /// Never fewer than the count the history used to be bounded by, however old: a bulb
    /// that missed the last few datagrams before a quiet passage is still showing one of
    /// them, and nothing Glowbeat sends will replace it until the music moves again.
    func testNeverFewerThanTheMinimumCountHoweverOld() {
        let history = streamed(8, minimumCount: 5)
        XCTAssertEqual(history.entries(asOf: start.addingTimeInterval(120)).map(\.color),
                       (3..<8).map(color))
    }

    /// A one shot is stamped when it is sent and a streamed color when its tick began, so
    /// a stamp can arrive a moment older than the one before it. The history is the order
    /// things went out, and it never runs backwards.
    func testSendTimesNeverRunBackwards() {
        var history = SentColorHistory(window: 3, minimumCount: 5)
        history.record(color(1), at: start.addingTimeInterval(1))
        history.record(color(2), at: start)
        let entries = history.entries(asOf: start.addingTimeInterval(1))
        XCTAssertEqual(entries.map(\.color), [color(1), color(2)])
        XCTAssertEqual(entries[1].sentAt, start.addingTimeInterval(1))
    }

    /// What is stored is bounded too, not just what is read back.
    func testOldEntriesAreDroppedAsNewOnesArrive() {
        let history = streamed(600)
        XCTAssertLessThanOrEqual(history.entries.count, 62)
        XCTAssertEqual(history.entries.last?.color, color(599))
    }

    func testAFloodAtOneInstantIsCapped() {
        var history = SentColorHistory(window: 3, minimumCount: 5)
        for index in 0..<1_000 {
            history.record(color(index), at: start)
        }
        XCTAssertEqual(history.entries.count, SentColorHistory.maximumCount)
        XCTAssertEqual(history.entries.last?.color, color(999))
    }
}
