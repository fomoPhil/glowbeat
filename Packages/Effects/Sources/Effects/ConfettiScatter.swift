import Foundation

/// Confetti's layout: a palette color for every bulb, never the same as the bulb on
/// either side of it.
///
/// Phil's words on 2026-09-23: "Every bulb gets its own color from the palette, and never
/// matches its neighbors." Neighbors are neighbors in the room's bulb order, which is the
/// order the user dragged the bulbs into; the ends of the row are not neighbors.
enum ConfettiScatter {

    /// The least two neighbors may differ, on their most different channel, at any moment
    /// of a change. Well clear of the rounding to whole channel values, so two fades that
    /// pass this close still never land on the same color.
    static let minimumFadeSeparation: Double = 8

    /// Palette positions, one per bulb, with no two neighbors equal.
    ///
    /// With a `previous` layout for the same room, every bulb also moves to a different
    /// color than it had, so a change shows on every bulb, and no two neighbors trade
    /// colors, which would put both on the same blend halfway through the crossfade. With
    /// three or more colors all three rules always leave a choice: a bulb rules out at
    /// most two colors, its left neighbor's new one and its own old one, or its old one
    /// and its left neighbor's old one when those two would otherwise trade.
    ///
    /// Two colors can only alternate, so a change flips which one leads. One color, or
    /// none, puts every bulb on the first position.
    static func scatter(count: Int,
                        paletteSize: Int,
                        previous: [Int]?,
                        using generator: inout SeededGenerator) -> [Int] {
        guard count > 0 else { return [] }
        guard paletteSize > 1 else { return Array(repeating: 0, count: count) }
        let old = previous?.count == count ? previous : nil

        guard paletteSize > 2 else {
            let lead = old.map { 1 - ($0[0] % 2) } ?? Int.random(in: 0...1, using: &generator)
            return (0..<count).map { (lead + $0) % 2 }
        }

        var layout: [Int] = []
        layout.reserveCapacity(count)
        for index in 0..<count {
            var excluded = Set<Int>()
            if index > 0 { excluded.insert(layout[index - 1]) }
            if let old {
                excluded.insert(old[index])
                if index > 0, layout[index - 1] == old[index] {
                    excluded.insert(old[index - 1])
                }
            }
            let choices = (0..<paletteSize).filter { !excluded.contains($0) }
            // Never empty with three or more colors (see above); the fallback only keeps
            // the function total.
            layout.append(choices.randomElement(using: &generator) ?? 0)
        }
        return layout
    }

    /// The same scatter, knowing the palette's colors, so a change also keeps neighbors
    /// apart while they fade and not only once they arrive.
    ///
    /// Two fades can cross. Fire's four colors differ only in green and Blacklight's
    /// violets only in red, so one bulb fading up that line while its neighbor fades down
    /// it pass through the same color part way. So a change is chosen as a whole rather
    /// than bulb by bulb: every pair of neighbors must stay `minimumFadeSeparation` apart
    /// through the entire fade and differ once it arrives, and within that, as few bulbs
    /// as possible keep the color they had. Usually none do. On a palette that is a line,
    /// a run of bulbs climbing it in order can only fade without crossing by staying put,
    /// and Phil's rule is the one that holds.
    ///
    /// Solved exactly along the row, one bulb at a time, from the far end back: for each
    /// bulb and each color, the fewest kept colors the rest of the row can manage. Then
    /// the row is walked forward choosing at random among the colors that still achieve
    /// that, so the scatter stays random.
    static func scatter(count: Int,
                        colors: [RGB],
                        previous: [Int]?,
                        using generator: inout SeededGenerator) -> [Int] {
        let size = colors.count
        guard size > 2, let previous, previous.count == count, count > 1 else {
            return scatter(count: count, paletteSize: size, previous: previous, using: &generator)
        }
        let old = previous.map { (($0 % size) + size) % size }

        // Whether bulb `index` may take `right` with the bulb before it taking `left`.
        func allowed(_ index: Int, _ left: Int, _ right: Int) -> Bool {
            guard left != right else { return false }
            // Neighbors that start on one color, a room fading apart as confetti is
            // switched on, cannot help meeting at the start.
            guard old[index - 1] != old[index], colors[old[index - 1]] != colors[old[index]] else {
                return true
            }
            return closestApproach(left: (colors[old[index - 1]], colors[left]),
                                   right: (colors[old[index]], colors[right]))
                >= minimumFadeSeparation
        }
        func kept(_ index: Int, _ color: Int) -> Int { color == old[index] ? 1 : 0 }

        let impossible = Int.max
        var fewest = Array(repeating: Array(repeating: impossible, count: size), count: count)
        for color in 0..<size { fewest[count - 1][color] = kept(count - 1, color) }
        for index in stride(from: count - 2, through: 0, by: -1) {
            for color in 0..<size {
                let rest = (0..<size)
                    .filter { fewest[index + 1][$0] != impossible && allowed(index + 1, color, $0) }
                    .map { fewest[index + 1][$0] }
                    .min()
                if let rest { fewest[index][color] = kept(index, color) + rest }
            }
        }
        guard let target = fewest[0].min(), target != impossible else {
            // Only a palette with two colors closer than the separation can get here.
            return scatter(count: count, paletteSize: size, previous: previous, using: &generator)
        }

        var layout = [(0..<size).filter { fewest[0][$0] == target }.randomElement(using: &generator) ?? 0]
        for index in 1..<count {
            let left = layout[index - 1]
            let remaining = fewest[index - 1][left] - kept(index - 1, left)
            let options = (0..<size).filter { fewest[index][$0] == remaining && allowed(index, left, $0) }
            layout.append(options.randomElement(using: &generator) ?? 0)
        }
        return layout
    }

    /// How close, on their most different channel, two neighbors' colors come while each
    /// crossfades from its old color to its new one over the same fade.
    ///
    /// The gap between them moves in a straight line from where it starts to where it
    /// ends, so its largest channel is convex and piecewise linear in how far the fade has
    /// come. Its low point is at an end, where one channel crosses zero, or where two
    /// channels are equally far apart, and those few moments are all checked.
    static func closestApproach(left: (from: RGB, to: RGB), right: (from: RGB, to: RGB)) -> Double {
        let start = [Double(right.from.r) - Double(left.from.r),
                     Double(right.from.g) - Double(left.from.g),
                     Double(right.from.b) - Double(left.from.b)]
        let end = [Double(right.to.r) - Double(left.to.r),
                   Double(right.to.g) - Double(left.to.g),
                   Double(right.to.b) - Double(left.to.b)]
        let slope = zip(start, end).map { $1 - $0 }
        func gap(_ progress: Double) -> Double {
            max(abs(start[0] + slope[0] * progress),
                abs(start[1] + slope[1] * progress),
                abs(start[2] + slope[2] * progress))
        }
        var moments: [Double] = [0, 1]
        for first in 0..<3 {
            if slope[first] != 0 { moments.append(-start[first] / slope[first]) }
            for second in (first + 1)..<3 {
                for sign in [1.0, -1.0] {
                    let rate = slope[first] - sign * slope[second]
                    if rate != 0 { moments.append((sign * start[second] - start[first]) / rate) }
                }
            }
        }
        return moments.filter { (0...1).contains($0) }.map(gap).min() ?? gap(0)
    }
}
