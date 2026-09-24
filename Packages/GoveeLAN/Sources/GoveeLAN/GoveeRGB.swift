import Foundation

/// An 8 bit per channel color as the Govee LAN protocol carries it.
public struct GoveeRGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = GoveeRGB(r: 0, g: 0, b: 0)

    /// The largest absolute per channel difference between two colors.
    public func channelDistance(to other: GoveeRGB) -> Int {
        let dr = abs(Int(r) - Int(other.r))
        let dg = abs(Int(g) - Int(other.g))
        let db = abs(Int(b) - Int(other.b))
        return max(dr, max(dg, db))
    }
}
