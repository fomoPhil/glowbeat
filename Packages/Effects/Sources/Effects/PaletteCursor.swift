import Foundation

/// Walks a palette's colors in order, wrapping at the end.
///
/// The first `advance` stays on the first color so the opening beat shows `colors[0]`;
/// every later advance steps one color along. Reads are taken modulo the palette size,
/// so switching to a shorter palette part way through a run is safe.
struct PaletteCursor: Hashable, Sendable {

    private var index = 0
    private var hasFired = false

    init() {}

    mutating func advance(in palette: Palette) {
        guard !palette.colors.isEmpty else { return }
        if hasFired {
            index = (index + 1) % palette.colors.count
        }
        hasFired = true
    }

    /// The current color, or the palette's dim base when the palette has no colors.
    func color(in palette: Palette) -> RGB {
        guard !palette.colors.isEmpty else { return palette.dimBase }
        return palette.colors[index % palette.colors.count]
    }

    mutating func reset() {
        index = 0
        hasFired = false
    }
}
