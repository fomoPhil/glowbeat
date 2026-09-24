import Foundation

/// The five bands Govee's desktop app splits audio into.
/// Source: the private protocol research notes section 4b.
public enum Band: Int, CaseIterable, Hashable, Sendable {
    case subBass = 0
    case bass
    case lowMid
    case mid
    case highMid

    public var displayName: String {
        switch self {
        case .subBass: return "Sub bass"
        case .bass: return "Bass"
        case .lowMid: return "Low mid"
        case .mid: return "Mid"
        case .highMid: return "High mid"
        }
    }
}

/// Five band energies, each normalized to 0 through 1.
public struct BandEnergies: Hashable, Sendable {

    public static let count = 5

    public private(set) var values: [Float]

    /// Pads with zeros or truncates so there are always exactly five values.
    public init(_ values: [Float]) {
        var padded = Array(values.prefix(Self.count))
        while padded.count < Self.count {
            padded.append(0)
        }
        self.values = padded
    }

    public subscript(band: Band) -> Float {
        get { values[band.rawValue] }
        set { values[band.rawValue] = newValue }
    }

    public static let zero = BandEnergies([0, 0, 0, 0, 0])
}
