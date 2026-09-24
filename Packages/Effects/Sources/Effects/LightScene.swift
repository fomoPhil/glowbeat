import Foundation

/// The non-music modes, as shown in the Scenes picker.
public enum SceneKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case breathe
    case colorFlow
    case candle
    case sunset
    case fixed = "static"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .breathe: return "Breathe"
        case .colorFlow: return "Color flow"
        case .candle: return "Candle"
        case .sunset: return "Sunset"
        case .fixed: return "Static"
        }
    }

    public var summary: String {
        switch self {
        case .breathe: return "Every bulb brightens and dims together."
        case .colorFlow: return "The palette drifts from bulb to bulb."
        case .candle: return "A warm flicker, different in every bulb."
        case .sunset: return "Twenty minutes from warm white down to off."
        case .fixed: return "One palette color per bulb, holding still."
        }
    }

    /// Whether the scene ends by itself. Only Sunset does, and only that one shows a
    /// progress bar.
    public var hasTimeline: Bool { self == .sunset }
}

/// A non-music light mode: color per bulb from a clock, with no audio anywhere in it.
///
/// Called `LightScene` rather than `Scene` because the app imports SwiftUI, whose own
/// `Scene` protocol every `App` body is written against. Two protocols of that name in
/// scope would make `some Scene` ambiguous in every file that has both imports.
///
/// Value types, like the effects, so a scene can be driven by a scripted clock in a test
/// and read straight back.
public protocol LightScene: Sendable {
    var kind: SceneKind { get }

    /// - Parameters:
    ///   - bulbCount: how many colors to return, in the user's bulb order. Empty for zero.
    ///   - palette: the colors to draw from, shared with Party Mode.
    ///   - speed: 0.25 through 4. Multiplies the scene's own clock.
    ///   - time: seconds on a monotonic clock.
    mutating func tick(bulbCount: Int,
                       palette: Palette,
                       speed: Double,
                       time: TimeInterval) -> [RGB]

    /// 0 through 1 for a scene that ends, `nil` for one that runs until it is switched
    /// off. Read after `tick`.
    var progress: Double? { get }

    /// True once a timed scene has reached its end. The engine turns the bulbs off and
    /// puts the Scenes control back to off.
    var isFinished: Bool { get }

    mutating func reset()
}

extension LightScene {
    public var progress: Double? { nil }
    public var isFinished: Bool { false }
}

extension SceneKind {

    /// How often scenes are sent. They are slow by nature, so four per second is smooth
    /// enough for a breath or a flicker and leaves the bulbs' own rate limit alone.
    public static let updatesPerSecond = 4

    /// The speed slider's range, quarter speed through four times speed.
    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let defaultSpeed: Double = 1

    public static func clampedSpeed(_ value: Double) -> Double {
        min(speedRange.upperBound, max(speedRange.lowerBound, value))
    }

    /// Builds a fresh scene of this kind. The engine calls this whenever the user picks
    /// one, so no state carries over between scenes.
    ///
    /// - Parameter singleColor: only Static has anything to do with this. Every other
    ///   scene ignores it, so the engine can pass what the user chose without asking which
    ///   scene is about to be built.
    public func makeScene(singleColor: Bool = false) -> any LightScene {
        switch self {
        case .breathe: return BreatheScene()
        case .colorFlow: return ColorFlowScene()
        case .candle: return CandleScene()
        case .sunset: return SunsetScene()
        case .fixed: return StaticScene(singleColor: singleColor)
        }
    }

    /// Whether the Single color switch means anything for this scene. The Scenes panel
    /// only shows the switch where it does.
    public var hasSingleColorMode: Bool { self == .fixed }
}

/// Shared bookkeeping: seconds of scene time since the first tick, with the speed
/// applied. Every scene keeps its own phase from this rather than from wall clock time,
/// so changing the speed mid scene bends the rest of it instead of jumping.
struct SceneClock: Hashable, Sendable {

    private(set) var elapsed: TimeInterval = 0
    private var lastTime: TimeInterval?

    init() {}

    /// Advances the clock and returns the scene seconds that just passed.
    mutating func advance(to time: TimeInterval, speed: Double) -> TimeInterval {
        let real = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        let scaled = real * SceneKind.clampedSpeed(speed)
        elapsed += scaled
        return scaled
    }

    mutating func reset() {
        elapsed = 0
        lastTime = nil
    }
}
