import Foundation

/// The palette flows along the bulbs in the user's list order, one bulb step every two
/// seconds at 1x, crossfading the whole way so it reads as a drift rather than as a set
/// of steps. A palette flows at the style's brightest. Custom colors flow as the high
/// point and the low point taking turns, so each bulb drifts between the two.
public struct ColorFlowScene: LightScene {

    /// Seconds for the pattern to move one bulb along, at 1x.
    public static let stepDuration: TimeInterval = 2

    public let kind: SceneKind = .colorFlow

    private var clock = SceneClock()

    public init() {}

    public mutating func tick(bulbCount: Int,
                              style: SceneStyle,
                              speed: Double,
                              time: TimeInterval) -> [RGB] {
        _ = clock.advance(to: time, speed: speed)

        let count = max(0, bulbCount)
        guard count > 0 else { return [] }

        // Custom colors are two stops, high then low, flowing the same way a palette does.
        // The colors only stand in for levels here; the style paints the level.
        let colors = style.palette?.colors ?? [RGB.white, RGB.black]
        guard !colors.isEmpty else {
            return Array(repeating: style.fallbackColor, count: count)
        }
        let levels: [Double] = style.isCustom ? [1, 0] : Array(repeating: 1, count: colors.count)
        let steps = clock.elapsed / Self.stepDuration
        let whole = steps.rounded(.down)
        let fraction = steps - whole

        return (0..<count).map { bulbIndex in
            // Subtracted, so the pattern travels down the list rather than up it.
            let position = Int((Double(bulbIndex) - whole).truncatingRemainder(dividingBy: Double(colors.count)))
            let index = ((position % colors.count) + colors.count) % colors.count
            let next = (index + colors.count - 1) % colors.count
            let level = levels[index] + (levels[next] - levels[index]) * fraction
            return style.color(at: level,
                               paletteColor: colors[index].blended(with: colors[next],
                                                                   amount: fraction))
        }
    }

    public mutating func reset() {
        clock.reset()
    }
}
