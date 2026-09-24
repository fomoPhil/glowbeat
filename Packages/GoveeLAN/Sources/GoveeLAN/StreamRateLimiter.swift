import Foundation

/// Coalesces streamed colors so no bulb receives more than `maxSendsPerSecond` updates.
///
/// Pure and date injected so the behavior is unit testable with no timers.
public struct StreamRateLimiter: Sendable {

    public var maxSendsPerSecond: Int {
        didSet { maxSendsPerSecond = max(1, maxSendsPerSecond) }
    }

    private var lastSend: [String: Date] = [:]
    private var held: [String: GoveeRGB] = [:]

    /// The range the app is allowed to stream in. Two per second is the slowest that
    /// still reads as motion, ten is as fast as an H6004 keeps up with. Every
    /// caller that takes a rate from configuration or from the UI clamps with
    /// `clampSendsPerSecond` so there is a single source of truth.
    public static let supportedSendsPerSecond: ClosedRange<Int> = 2...10

    /// The shipped ceiling on what Party Mode streams each bulb at: the top of the
    /// supported range. Eight was the cautious first guess; six H6004 bulbs on Phil's own
    /// Wi-Fi kept up with ten, and the extra two frames a second are the difference
    /// between a wave that steps and one that moves. More bulbs than six share
    /// `roomBudgetPerSecond` instead (`perBulbSendsPerSecond`), and a busier network is
    /// what the slider in Settings is for.
    public static let defaultSendsPerSecond = 10

    public static func clampSendsPerSecond(_ value: Int) -> Int {
        min(supportedSendsPerSecond.upperBound, max(supportedSendsPerSecond.lowerBound, value))
    }

    // MARK: The room's budget

    /// The most streamed `colorwc` datagrams a second Party Mode sends to the whole room.
    ///
    /// A per bulb rate alone let the room grow with every bulb: six bulbs at ten a second
    /// was sixty datagrams a second and felt smooth, ten bulbs at ten a second was a
    /// hundred, in bursts of ten, and felt jerky and late (smoothness investigation H5,
    /// 2026-09-23). Phil's own test at six a second on ten bulbs, sixty again, felt smooth.
    /// So sixty is the room, whatever size the room is.
    public static let roomBudgetPerSecond = 60

    /// The rate each bulb actually streams at: the room budget shared out between the
    /// bulbs, never more than `ceiling`, which is the user's Settings slider, and never
    /// below the slowest supported rate.
    ///
    /// Six bulbs run at ten a second, ten bulbs at six, fifteen at four. A room of more
    /// than thirty bulbs stays at two a second and goes over the budget, because anything
    /// slower no longer reads as motion. No bulbs at all is the ceiling.
    public static func perBulbSendsPerSecond(ceiling: Int, bulbCount: Int) -> Int {
        let share = roomBudgetPerSecond / max(1, bulbCount)
        return min(clampSendsPerSecond(ceiling), max(supportedSendsPerSecond.lowerBound, share))
    }

    // MARK: Spreading one tick

    /// How long one tick's datagrams are spread over, rather than leaving in one burst.
    ///
    /// Twenty milliseconds of difference between the first bulb and the last is well
    /// under what the eye reads as the room being out of step, and well inside a tick
    /// (100 ms at ten a second), so the spread never reaches into the next one.
    public static let tickSpread: TimeInterval = 0.020

    /// How far into a tick the bulb in `slot` (its place in the room, from 0) is sent.
    ///
    /// A fixed slot per bulb rather than a gap between whichever bulbs happen to send on
    /// a tick, so each bulb's own sends stay exactly one tick apart however many of the
    /// others the deduper skipped.
    public static func sendOffset(forSlot slot: Int, of bulbCount: Int) -> TimeInterval {
        guard bulbCount > 1 else { return 0 }
        let clamped = min(bulbCount - 1, max(0, slot))
        return tickSpread * Double(clamped) / Double(bulbCount)
    }

    public init(maxSendsPerSecond: Int) {
        self.maxSendsPerSecond = max(1, maxSendsPerSecond)
    }

    /// How much of the nominal gap a send is allowed to arrive early. The engine ticks
    /// at exactly `minimumGap`, and a timer plus an actor hop puts a few milliseconds of
    /// jitter on either side of that. Without the tolerance the early half of the jitter
    /// is held back and superseded by the next tick, so alternate frames never reach the
    /// bulbs and Wave visibly skips. Twenty percent of the gap is 20 ms at ten sends a
    /// second, which is far more jitter than a timer produces and still nowhere near
    /// doubling the real send rate.
    static let gapTolerance = 0.8

    private var minimumGap: TimeInterval {
        1.0 / Double(maxSendsPerSecond)
    }

    /// The gap actually enforced, tolerance included.
    private var effectiveGap: TimeInterval {
        minimumGap * Self.gapTolerance
    }

    /// Returns the color to send right now, or nil when the send must wait.
    /// A held color replaces any previously held color for that bulb: latest value wins.
    public mutating func submit(_ color: GoveeRGB, for bulbID: String, now: Date) -> GoveeRGB? {
        if let last = lastSend[bulbID], now.timeIntervalSince(last) < effectiveGap {
            held[bulbID] = color
            return nil
        }
        lastSend[bulbID] = now
        held[bulbID] = nil
        return color
    }

    /// Returns every held color whose minimum gap has now elapsed.
    public mutating func drain(now: Date) -> [(bulbID: String, color: GoveeRGB)] {
        var released: [(bulbID: String, color: GoveeRGB)] = []
        for (bulbID, color) in held {
            guard let last = lastSend[bulbID] else {
                lastSend[bulbID] = now
                released.append((bulbID, color))
                continue
            }
            if now.timeIntervalSince(last) >= effectiveGap {
                lastSend[bulbID] = now
                released.append((bulbID, color))
            }
        }
        for entry in released {
            held[entry.bulbID] = nil
        }
        return released.sorted { $0.bulbID < $1.bulbID }
    }

    public mutating func reset() {
        lastSend.removeAll()
        held.removeAll()
    }
}
