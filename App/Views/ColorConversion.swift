import AppKit
import Effects
import SwiftUI

extension Color {
    init(effectsRGB color: Effects.RGB) {
        self.init(.sRGB,
                  red: Double(color.r) / 255,
                  green: Double(color.g) / 255,
                  blue: Double(color.b) / 255,
                  opacity: 1)
    }
}

enum ColorConversion {
    /// SwiftUI colors can come from any color space, so convert through sRGB before
    /// taking the channels the bulbs expect.
    static func effectsRGB(from color: Color) -> Effects.RGB {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8(min(255, max(0, (value * 255).rounded())))
        }
        return Effects.RGB(r: channel(resolved.redComponent),
                           g: channel(resolved.greenComponent),
                           b: channel(resolved.blueComponent))
    }
}

extension ColorConversion {

    /// Roughly what a given white temperature looks like, for a swatch.
    ///
    /// Three measured points off a blackbody curve with a straight line between them,
    /// rather than the full Planckian locus: this paints a 22 point square, and the
    /// difference between an exact 3400 K and an interpolated one is not visible at that
    /// size. The ends are the H6004's own range.
    static func approximateWhite(kelvin: Int) -> Color {
        let stops: [(kelvin: Double, red: Double, green: Double, blue: Double)] = [
            (2700, 255, 180, 107),
            (4000, 255, 219, 186),
            (6500, 255, 249, 253)
        ]
        let value = Double(ColorTemperatureRange.clamp(kelvin))
        var low = stops[0]
        var high = stops[stops.count - 1]
        for index in 1..<stops.count where value <= stops[index].kelvin {
            low = stops[index - 1]
            high = stops[index]
            break
        }
        let span = high.kelvin - low.kelvin
        let fraction = span > 0 ? (value - low.kelvin) / span : 0
        func channel(_ from: Double, _ to: Double) -> Double {
            (from + (to - from) * fraction) / 255
        }
        return Color(.sRGB,
                     red: channel(low.red, high.red),
                     green: channel(low.green, high.green),
                     blue: channel(low.blue, high.blue),
                     opacity: 1)
    }
}

extension ColorConversion {

    /// What a still color looks like on screen.
    ///
    /// A white is painted in the white it really is rather than in plain white, which is
    /// the whole reason the Whites row reads as a row of six different lights instead of
    /// six identical rectangles. The same approximation the bulb row's Kelvin swatch
    /// uses, so the two features cannot disagree about what 3000 K looks like.
    static func swatch(for color: StillColor) -> Color {
        switch color.value {
        case .white(let kelvin):
            return approximateWhite(kelvin: kelvin)
        case .rgb(let rgb):
            return Color(effectsRGB: rgb)
        }
    }
}
