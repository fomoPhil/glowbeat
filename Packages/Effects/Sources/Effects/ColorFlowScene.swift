import Foundation

/// The palette flows along the bulbs in the user's list order, one bulb step every two
/// seconds at 1x, crossfading the whole way so it reads as a drift rather than as a set
/// of steps.
public struct ColorFlowScene: LightScene {

    /// Seconds for the pattern to move one bulb along, at 1x.
    public static let stepDuration: TimeInterval = 2

    public let kind: SceneKind = .colorFlow

    private var clock = SceneClock()

    public init() {}

    public mutating func tick(bulbCount: Int,
                              palette: Palette,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        _ = clock.advance(to: time, speed: speed)

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }
        guard !palette.colors.isEmpty else {
            return Array(repeating: palette.dimBase, count: count)
        }

        let colors = palette.colors
        let steps = clock.elapsed / Self.stepDuration
        let whole = steps.rounded(.down)
        let fraction = steps - whole

        return (0..<count).map { bulbIndex in
            // Subtracted, so the pattern travels down the list rather than up it.
            let position = Int((Double(bulbIndex) - whole).truncatingRemainder(dividingBy: Double(colors.count)))
            let index = ((position % colors.count) + colors.count) % colors.count
            let next = (index + colors.count - 1) % colors.count
            return colors[index].blended(with: colors[next], amount: fraction)
        }
    }

    public mutating func reset() {
        clock.reset()
    }
}
