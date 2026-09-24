import Foundation

/// The white the room sits at when nothing else is driving it.
///
/// Daylight and Night are fixed temperatures the user picks outright. Auto follows the
/// Mac: Night Shift's own on and off flag where that is readable, and sunrise and sunset
/// where it is not. `LightModeEngine` owns the following; this is only the choice.
enum LightMode: String, CaseIterable, Identifiable, Sendable {
    case daylight
    case night
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daylight: return "Daylight"
        case .night: return "Night"
        case .auto: return "Auto"
        }
    }

    /// The temperature this mode asks for on its own, or nil for Auto, which has none:
    /// it borrows Daylight's or Night's depending on the time of day.
    var fixedKelvin: Int? {
        switch self {
        case .daylight: return WhiteTemperature.daylightKelvin
        case .night: return WhiteTemperature.nightKelvin
        case .auto: return nil
        }
    }
}

/// The one place a white temperature is clamped.
///
/// Govee's LAN protocol advertises 2000 to 9000 K, but the H6004 is a 2700 to 6500 K
/// bulb and a value outside that is silently ignored: the bulb keeps its old value,
/// returns no error and reports the old value on the next status poll. There is nothing
/// to catch, so an unclamped Kelvin is an invisible no op rather than a visible failure.
/// Research: `docs/research/sleep-wake-nightshift-research.md` section D2.
enum WhiteTemperature {
    /// The H6004's warm end, which is also the warm end of the Mac's own Night Shift
    /// range on the machine the research was run on.
    static let minimumKelvin = 2700
    /// The H6004's retail cool end. Untested against the hardware: the open question in
    /// the research is whether the bulb really reaches it.
    static let maximumKelvin = 6500

    static let nightKelvin = 2700
    static let daylightKelvin = 6000

    static func clamped(_ kelvin: Int) -> Int {
        min(maximumKelvin, max(minimumKelvin, kelvin))
    }

    /// The `Double` overload a ramp lands on.
    ///
    /// The comparisons come before the conversion on purpose: `Int(Double.infinity)`
    /// traps, and so does anything past `Int.max`, so an infinity clamps to the end of
    /// the range it is on and only a value that is not a number at all falls back.
    static func clamped(_ kelvin: Double) -> Int {
        guard !kelvin.isNaN else { return daylightKelvin }
        guard kelvin > Double(minimumKelvin) else { return minimumKelvin }
        guard kelvin < Double(maximumKelvin) else { return maximumKelvin }
        return clamped(Int(kelvin.rounded()))
    }
}
