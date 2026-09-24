import Foundation

/// An energy beat detector modeled on the one in Govee's Windows desktop app.
///
/// Its starting constants match that app's behavior: a 20 frame history, a 0.5
/// energy margin, a 0.1 s minimum interval, five bands.
public struct BeatDetector: Sendable {

    /// The rolling energy window, in frames.
    public static let historyEnergyCount = 20
    /// Govee's own margin above the window mean, kept as the historical reference.
    /// Glowbeat's slider no longer passes through it: see `thresholdMultiplier`.
    public static let minBeatEnergyThreshold: Float = 0.5
    /// Per band debounce, in seconds.
    public static let minBeatInterval: TimeInterval = 0.1
    /// A floor so that near silence never beats no matter how flat the window is.
    public static let minimumAbsoluteEnergy: Float = 0.02

    /// 0 through 1. 0 asks for 1.65 times the rolling mean, 1 asks for 1.2 times it,
    /// so a higher value fires more often. See `thresholdMultiplier(forSensitivity:)`.
    public var sensitivity: Double {
        didSet { sensitivity = min(1, max(0, sensitivity)) }
    }

    private var history: [BandEnergies] = []
    private var lastBeatTime: [TimeInterval?]

    public init(sensitivity: Double = 0.5) {
        self.sensitivity = min(1, max(0, sensitivity))
        self.lastBeatTime = Array(repeating: nil, count: BandEnergies.count)
        self.history.reserveCapacity(Self.historyEnergyCount)
    }

    /// The strictest the slider gets: an energy must be 1.65 times the rolling mean.
    /// Past this the detector starves on real music, because a dense mix keeps the bass
    /// band busy between kicks and a kick only reaches about 1.5 to 1.6 times the mean.
    public static let strictestMultiplier: Float = 1.65
    /// The loosest the slider gets: 1.2 times the mean. Below this the detector fires
    /// eight or more times a second on a dance track, which lights the room solid
    /// instead of pulsing it.
    public static let loosestMultiplier: Float = 1.2

    /// The multiplier the current energy must beat, for a given sensitivity.
    ///
    /// A straight line from `strictestMultiplier` at sensitivity 0 to
    /// `loosestMultiplier` at 1, so the middle of the slider asks for 1.425 times the
    /// rolling mean. Note that Govee's own raw constant, 1.5 times the mean
    /// (`minBeatEnergyThreshold` plus one), is no longer a named point on the curve: it
    /// lands near sensitivity 0.33 and is kept only as the historical reference.
    ///
    /// The range comes from replaying real tracks through the whole pipeline on
    /// 2026-09-14. Low band beats per second, at Phil's marker position:
    ///
    ///     multiplier  dance remix  hip hop mix  ambient  jazz
    ///     1.15x       8.8          7.7          4.9      5.4
    ///     1.35x       7.0          3.5          2.4      4.0
    ///     1.65x       5.2          0.6          1.3      2.9
    ///     2.00x       3.5          0.04         0.6      2.2
    ///
    /// Everything usable sits between about 1.2 and 1.65. The earlier curve ran 2.5 to
    /// 1.08 through Govee's 1.5, which spent the whole top half of the marker above the
    /// window: a hip hop mix went four seconds between pulses, with gaps up to forty.
    /// The curve is strictly decreasing, so turning the slider up can only ever fire
    /// more beats.
    public static func thresholdMultiplier(forSensitivity sensitivity: Double) -> Float {
        let value = Float(min(1, max(0, sensitivity)))
        return strictestMultiplier + (loosestMultiplier - strictestMultiplier) * value
    }

    public mutating func process(_ frame: AudioFrame) -> [BeatEvent] {
        defer {
            history.append(frame.bands)
            if history.count > Self.historyEnergyCount {
                history.removeFirst(history.count - Self.historyEnergyCount)
            }
        }

        guard history.count == Self.historyEnergyCount else { return [] }

        let multiplier = Self.thresholdMultiplier(forSensitivity: sensitivity)
        var beats: [BeatEvent] = []

        for band in Band.allCases {
            let energy = frame.bands[band]
            guard energy >= Self.minimumAbsoluteEnergy else { continue }

            var total: Float = 0
            for snapshot in history {
                total += snapshot[band]
            }
            let mean = total / Float(Self.historyEnergyCount)
            guard energy > mean * multiplier else { continue }

            if let last = lastBeatTime[band.rawValue],
               frame.time - last < Self.minBeatInterval {
                continue
            }
            lastBeatTime[band.rawValue] = frame.time
            beats.append(BeatEvent(band: band, time: frame.time, energy: energy))
        }

        return beats
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
        lastBeatTime = Array(repeating: nil, count: BandEnergies.count)
    }
}
