import Foundation

/// The state a bulb reports through `devStatus`, and the state the app tracks for it.
public struct BulbState: Hashable, Sendable {
    /// True when the bulb is powered on.
    public var isOn: Bool
    /// 0 through 100 on H6004. Other SKUs may use 0 through 255; the app clamps to 100.
    public var brightness: Int
    /// The last reported color. Meaningless while the bulb is in white mode.
    public var color: GoveeRGB
    /// Nonzero when the bulb is in white mode.
    public var colorTemperatureKelvin: Int

    public init(isOn: Bool, brightness: Int, color: GoveeRGB, colorTemperatureKelvin: Int) {
        self.isOn = isOn
        self.brightness = brightness
        self.color = color
        self.colorTemperatureKelvin = colorTemperatureKelvin
    }

    public static let unknown = BulbState(isOn: false,
                                          brightness: 0,
                                          color: .black,
                                          colorTemperatureKelvin: 0)
}
