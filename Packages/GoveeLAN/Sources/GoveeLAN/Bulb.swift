import Foundation

/// One Govee bulb on the local network.
public struct Bulb: Identifiable, Hashable, Sendable {
    /// The `device` string from the scan reply, a MAC style identifier. Stable across
    /// IP changes, which is why names and order are keyed on it.
    public var id: String
    public var sku: String
    /// Where commands go. The host comes from the scan reply, the port from configuration.
    public var endpoint: LANEndpoint
    public var bleVersionHard: String
    public var bleVersionSoft: String
    public var wifiVersionHard: String
    public var wifiVersionSoft: String
    /// The last state the bulb reported. Nil until the first `devStatus` reply.
    public var state: BulbState?
    public var isReachable: Bool
    public var lastSeen: Date

    public init(id: String,
                sku: String,
                endpoint: LANEndpoint,
                bleVersionHard: String = "",
                bleVersionSoft: String = "",
                wifiVersionHard: String = "",
                wifiVersionSoft: String = "",
                state: BulbState? = nil,
                isReachable: Bool = true,
                lastSeen: Date = Date()) {
        self.id = id
        self.sku = sku
        self.endpoint = endpoint
        self.bleVersionHard = bleVersionHard
        self.bleVersionSoft = bleVersionSoft
        self.wifiVersionHard = wifiVersionHard
        self.wifiVersionSoft = wifiVersionSoft
        self.state = state
        self.isReachable = isReachable
        self.lastSeen = lastSeen
    }
}
