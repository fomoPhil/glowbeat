import Foundation

/// Where a color sits at one moment: part way through a crossfade from one palette entry
/// to another.
///
/// Held as two palette positions and how far along the fade is, rather than as a finished
/// color, so an effect that shades a palette color can shade both ends first and then mix
/// them. Spread's high group blending from one pale color to the next reads as the same
/// shade throughout; shading a blend of two raw colors would not.
struct PaletteBlend: Hashable, Sendable {
    /// The palette position the fade started from.
    var from: Int
    /// The palette position the fade is heading to.
    var to: Int
    /// 0 at the start of the fade, 1 once it has arrived.
    var progress: Double

    /// A color already arrived at one palette position.
    static func settled(at index: Int) -> PaletteBlend {
        PaletteBlend(from: index, to: index, progress: 1)
    }

    /// The color, straight from the palette.
    func color(in palette: Palette) -> RGB {
        color(in: palette) { palette.colors[$0] }
    }

    /// The color with each end passed through `tone` first. `tone` is handed a position
    /// already inside the palette, so a switch to a shorter palette mid session reads
    /// round rather than off the end. A palette with no colors has nothing to fade
    /// between, and every bulb gets its dim base.
    func color(in palette: Palette, tone: (Int) -> RGB) -> RGB {
        let count = palette.colors.count
        guard count > 0 else { return palette.dimBase }
        let start = tone(Self.wrapped(from, count: count))
        let end = tone(Self.wrapped(to, count: count))
        return start.blended(with: end, amount: progress)
    }

    private static func wrapped(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}
