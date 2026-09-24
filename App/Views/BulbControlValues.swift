import GoveeLAN
import SwiftUI

/// One bulb's controls as the screen is showing them, and the rules for letting a polled
/// reading back in.
///
/// Every control the app puts on a bulb is optimistic. The bulbs answer a command by
/// reporting their new state on the next status poll, which is up to ten seconds away
/// when Party Mode is off, so a control that waited for the poll would visibly snap back
/// to the old value and then forward again. Each one shows what the user chose and only
/// accepts a polled reading once `ControlSettle.duration` has passed with no further
/// change.
///
/// This is a value type rather than a pile of `@State` in one view because two views now
/// draw the same bulb: the row in the Bulbs pane and the tile in the strip along the
/// bottom. Two copies of these rules would drift, and a row and a tile disagreeing about
/// whether a bulb is on is exactly the kind of thing nobody would notice until it shipped.
struct BulbControlValues {

    var power = false
    var brightness: Double = 100
    var kelvin = Double(ColorTemperatureRange.neutral)
    var color = Color.white

    /// The exact `Color` the last sync wrote into the well. Comparing against this, not
    /// against a converted value, is what keeps a status poll from looking like a user
    /// turning the well and firing a `colorwc` back at a bulb Party Mode is driving.
    private(set) var lastSyncedColor: Color?

    private var powerChangedAt: Date?
    private var brightnessChangedAt: Date?
    private var kelvinChangedAt: Date?
    private var colorChangedAt: Date?

    // MARK: What the user just did

    mutating func touchPower(at date: Date = Date()) { powerChangedAt = date }
    mutating func touchBrightness(at date: Date = Date()) { brightnessChangedAt = date }
    mutating func touchKelvin(at date: Date = Date()) { kelvinChangedAt = date }
    mutating func touchColor(at date: Date = Date()) { colorChangedAt = date }

    /// True when the well was turned by a person rather than written by a sync.
    func isUserColor(_ candidate: Color) -> Bool {
        candidate != lastSyncedColor
    }

    // MARK: What the bulb says

    /// Folds a polled reading in, skipping anything the user has touched recently.
    ///
    /// `force` is the first load of a bulb, where there is nothing of the user's to
    /// protect and every stamp is cleared. `isFlashing` is Identify, which is deliberately
    /// turning the bulb on and off for a second and a half: following it with the switch
    /// and the color well would make the control look like something was fighting over it.
    mutating func sync(with state: BulbState?,
                       force: Bool,
                       isFlashing: Bool,
                       isEditingBrightness: Bool = false,
                       isEditingKelvin: Bool = false,
                       now: Date = Date()) {
        guard let state else { return }

        if force || (!isFlashing && !ControlSettle.isSettling(since: powerChangedAt, now: now)) {
            power = state.isOn
            if force { powerChangedAt = nil }
        }
        if !isEditingBrightness,
           force || !ControlSettle.isSettling(since: brightnessChangedAt, now: now) {
            brightness = Double(min(100, max(0, state.brightness)))
            if force { brightnessChangedAt = nil }
        }
        if state.colorTemperatureKelvin > 0,
           !isEditingKelvin,
           force || !ControlSettle.isSettling(since: kelvinChangedAt, now: now) {
            kelvin = Double(ColorTemperatureRange.clamp(state.colorTemperatureKelvin))
            if force { kelvinChangedAt = nil }
        }
        if force || (!isFlashing && !ControlSettle.isSettling(since: colorChangedAt, now: now)) {
            let synced = Color(effectsRGB: FrameBridge.effectsColor(from: state.color))
            lastSyncedColor = synced
            color = synced
            if force { colorChangedAt = nil }
        }
    }

    /// The color to paint a swatch with: the bulb's own color, or the white it is sitting
    /// on when it is in white mode.
    ///
    /// A bulb put into white mode reports its color as black, so a swatch drawn straight
    /// from the reading would be a black square on a lit bulb.
    func swatchColor(for state: BulbState?) -> Color {
        guard let state, state.colorTemperatureKelvin > 0 else { return color }
        return ColorConversion.approximateWhite(kelvin: state.colorTemperatureKelvin)
    }
}
