import Foundation

/// A deliberate command `BulbController` put on the wire, reported to an observer.
///
/// Streamed Party Mode colors are not reported here: the engine that streams them gets
/// each one's fate straight back from `streamColor` and `flushStreamed`. This is for
/// everything else, the one shot commands and their repeats, which is exactly what a
/// diagnostic trace needs to see arriving while Party Mode owns the bulbs.
public enum BulbCommandEvent: Hashable, Sendable {

    /// Which command a repeat belongs to.
    public enum Kind: String, Hashable, Sendable {
        case power
        case brightness
        case color
    }

    case power(on: Bool, bulbIDs: [String])
    case brightness(Int, bulbIDs: [String])
    case color(GoveeRGB, bulbIDs: [String])
    case colorTemperature(kelvin: Int, bulbIDs: [String])
    /// One of the scheduled repeats of an earlier one shot command.
    case repeated(Kind, bulbID: String)
}
