import Foundation

/// An 8 bit per channel color produced by an effect.
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 255, g: 255, b: 255)

    /// Rec. 601 luma, 0 through 255. Close enough to what the eye calls brightness for
    /// deciding whether two shades of one color read as different from each other.
    public var luminance: Double {
        0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }

    /// The largest absolute per channel difference between two colors.
    public func channelDistance(to other: RGB) -> Int {
        let dr = abs(Int(r) - Int(other.r))
        let dg = abs(Int(g) - Int(other.g))
        let db = abs(Int(b) - Int(other.b))
        return max(dr, max(dg, db))
    }

    /// The HSV hue, in degrees from 0 through 360, with red at 0. A gray has no hue and
    /// reports 0.
    var hueDegrees: Double {
        let red = Double(r), green = Double(g), blue = Double(b)
        let high = max(red, green, blue)
        let span = high - min(red, green, blue)
        guard span > 0 else { return 0 }
        let sector: Double
        if high == red {
            sector = (green - blue) / span
        } else if high == green {
            sector = (blue - red) / span + 2
        } else {
            sector = (red - green) / span + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// How far apart two hues sit on the color wheel, 0 through 180 degrees.
    func hueDistance(to other: RGB) -> Double {
        let apart = abs(hueDegrees - other.hueDegrees)
        return min(apart, 360 - apart)
    }
}

extension RGB {

    /// Builds a color from a 0xRRGGBB literal.
    public init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF),
                  g: UInt8((hex >> 8) & 0xFF),
                  b: UInt8(hex & 0xFF))
    }

    /// Linear blend. `amount` 0 returns the receiver, 1 returns `other`, and values
    /// outside 0 through 1 are clamped.
    public func blended(with other: RGB, amount: Double) -> RGB {
        let mix = min(1, max(0, amount))
        func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
            let value = Double(from) + (Double(to) - Double(from)) * mix
            return UInt8(min(255, max(0, value.rounded())))
        }
        return RGB(r: channel(r, other.r), g: channel(g, other.g), b: channel(b, other.b))
    }

    /// Multiplies every channel, clamped to 0 through 255.
    public func scaled(by factor: Double) -> RGB {
        let scale = max(0, factor)
        func channel(_ value: UInt8) -> UInt8 {
            UInt8(min(255, max(0, (Double(value) * scale).rounded())))
        }
        return RGB(r: channel(r), g: channel(g), b: channel(b))
    }
}
