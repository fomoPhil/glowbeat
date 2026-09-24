import Foundation

/// How the app learns which port to send commands to.
public enum CommandPort: Hashable, Sendable {
    /// Real bulbs: always 4003.
    case fixed(UInt16)
    /// Tests: `FakeBulb` binds an ephemeral port and replies from it.
    case matchingReplySource
}

/// Ports and addresses for the Govee LAN protocol.
public struct LANConfiguration: Sendable {
    public var multicastGroup: String
    public var scanPort: UInt16
    /// Bulbs always reply here. Production uses 4002; 0 means bind an ephemeral port.
    public var replyPort: UInt16
    public var commandPort: CommandPort
    public var joinsMulticast: Bool
    /// Extra unicast targets for the scan request, used by tests and by slow networks.
    public var extraScanTargets: [LANEndpoint]

    public init(multicastGroup: String = "239.255.255.250",
                scanPort: UInt16 = 4001,
                replyPort: UInt16 = 4002,
                commandPort: CommandPort = .fixed(4003),
                joinsMulticast: Bool = true,
                extraScanTargets: [LANEndpoint] = []) {
        self.multicastGroup = multicastGroup
        self.scanPort = scanPort
        self.replyPort = replyPort
        self.commandPort = commandPort
        self.joinsMulticast = joinsMulticast
        self.extraScanTargets = extraScanTargets
    }

    /// Verified on Phil's six H6004 bulbs on 2026-09-11.
    public static let production = LANConfiguration()
}

public enum LANSocketError: Error, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case optionFailed(String, Int32)
    case noLocalIPv4Address
}
