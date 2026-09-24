import Foundation

/// Suppresses sends when a bulb's new color is not visibly different from the last color
/// actually sent to it. Quiet passages then send nothing at all.
///
/// Comparison is always against the last color that was sent, never against the last
/// color that was offered, so a slow drift still crosses the threshold eventually.
public struct ColorDeduper: Sendable {

    public static let defaultMinimumChannelDelta = 6

    public var minimumChannelDelta: Int {
        didSet { minimumChannelDelta = max(0, minimumChannelDelta) }
    }

    private var lastSent: [String: RGB] = [:]

    public init(minimumChannelDelta: Int = ColorDeduper.defaultMinimumChannelDelta) {
        self.minimumChannelDelta = max(0, minimumChannelDelta)
    }

    /// Returns true when the color should go on the wire, and records it as sent.
    public mutating func shouldSend(_ color: RGB, for key: String) -> Bool {
        guard let previous = lastSent[key] else {
            lastSent[key] = color
            return true
        }
        // A floor of 1 means a delta of 0 still suppresses exact duplicates.
        guard previous.channelDistance(to: color) >= max(1, minimumChannelDelta) else {
            return false
        }
        lastSent[key] = color
        return true
    }

    public mutating func forget(_ key: String) {
        lastSent[key] = nil
    }

    public mutating func reset() {
        lastSent.removeAll()
    }
}
