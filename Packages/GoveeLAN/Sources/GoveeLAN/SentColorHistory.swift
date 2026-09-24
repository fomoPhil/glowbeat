import Foundation

/// Every color recently sent to one bulb, oldest first, each stamped with when it went out.
///
/// Phone takeover detection asks it one question: what could this bulb have been showing
/// when it answered a status poll at a given moment? An H6004 does not jump to a
/// `colorwc` color, it fades there over 0.3 to 1 s. On a busy network it can also be a
/// datagram or two behind, and its reply can come back late. So the answer is every color
/// sent in the `window` before that moment, plus the one the bulb was already showing or
/// fading from when the window opened, and never fewer than the last `minimumCount`
/// however old they are. The order matters as much as the colors: the bulb fades from
/// each one to the next.
///
/// Pure and date injected, so it is unit testable with no clock.
public struct SentColorHistory: Sendable, Equatable {

    public struct Entry: Hashable, Sendable {
        public var color: GoveeRGB
        public var sentAt: Date

        public init(color: GoveeRGB, sentAt: Date) {
            self.color = color
            self.sentAt = sentAt
        }
    }

    /// A ceiling on what one bulb's history holds, whatever the send rate. Party Mode tops
    /// out at ten sends a second, which the time bound alone keeps near sixty entries.
    /// This only matters if something floods the controller.
    public static let maximumCount = 256

    public let window: TimeInterval
    public let minimumCount: Int
    /// Everything retained, oldest first. This is more than any one question needs: see
    /// `record(_:at:)` for what is kept and why.
    public private(set) var entries: [Entry] = []

    public init(window: TimeInterval, minimumCount: Int) {
        self.window = max(0, window)
        self.minimumCount = min(Self.maximumCount, max(1, minimumCount))
    }

    /// Records one send.
    ///
    /// The stamp never runs backwards, even if the wall clock does, because the order the
    /// colors went out is the order the bulb fades through them.
    ///
    /// Everything within two windows of this send is kept, plus the newest entry older
    /// than that. A reply is judged a moment after it arrives, and later sends can go out
    /// in that moment, so keeping a second window means the answer is exactly the one it
    /// would have been on arrival. Anything older can never be asked about again and is
    /// dropped, down to `minimumCount`.
    public mutating func record(_ color: GoveeRGB, at time: Date) {
        let stamp = max(time, entries.last?.sentAt ?? time)
        entries.append(Entry(color: color, sentAt: stamp))

        let horizon = stamp.addingTimeInterval(-2 * window)
        var dropped = 0
        while entries.count - dropped > minimumCount, entries[dropped + 1].sentAt < horizon {
            dropped += 1
        }
        dropped = max(dropped, entries.count - Self.maximumCount)
        if dropped > 0 {
            entries.removeFirst(dropped)
        }
    }

    /// The colors that could explain a status reply received at `time`, oldest first:
    /// every one sent in the `window` before it, the one sent just before the window
    /// opened (what the bulb was holding, or fading from, at that point), and never fewer
    /// than the last `minimumCount`. Colors sent after `time` are included too; they are
    /// only there when the reply is being judged late, and they cost nothing.
    public func entries(asOf time: Date) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        let opened = time.addingTimeInterval(-window)
        let firstInside = entries.firstIndex { $0.sentAt >= opened } ?? entries.count
        let fromWindow = max(0, firstInside - 1)
        let fromMinimum = max(0, entries.count - minimumCount)
        return Array(entries[min(fromWindow, fromMinimum)...])
    }
}
