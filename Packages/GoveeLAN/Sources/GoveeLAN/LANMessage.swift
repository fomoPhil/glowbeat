import Foundation

/// A reply a bulb sends back on the reply port.
public enum LANReply: Hashable, Sendable {
    case scan(ScanReply)
    case status(StatusReply)
}

/// The payload of a `scan` reply. Version fields default to an empty string because
/// not every firmware sends all of them.
public struct ScanReply: Codable, Hashable, Sendable {
    public var ip: String
    public var device: String
    public var sku: String
    public var bleVersionHard: String
    public var bleVersionSoft: String
    public var wifiVersionHard: String
    public var wifiVersionSoft: String

    public init(ip: String,
                device: String,
                sku: String = "",
                bleVersionHard: String = "",
                bleVersionSoft: String = "",
                wifiVersionHard: String = "",
                wifiVersionSoft: String = "") {
        self.ip = ip
        self.device = device
        self.sku = sku
        self.bleVersionHard = bleVersionHard
        self.bleVersionSoft = bleVersionSoft
        self.wifiVersionHard = wifiVersionHard
        self.wifiVersionSoft = wifiVersionSoft
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        device = try container.decode(String.self, forKey: .device)
        sku = try container.decodeIfPresent(String.self, forKey: .sku) ?? ""
        bleVersionHard = try container.decodeIfPresent(String.self, forKey: .bleVersionHard) ?? ""
        bleVersionSoft = try container.decodeIfPresent(String.self, forKey: .bleVersionSoft) ?? ""
        wifiVersionHard = try container.decodeIfPresent(String.self, forKey: .wifiVersionHard) ?? ""
        wifiVersionSoft = try container.decodeIfPresent(String.self, forKey: .wifiVersionSoft) ?? ""
    }
}

/// The payload of a `devStatus` reply.
public struct StatusReply: Hashable, Sendable {
    public var state: BulbState

    public init(state: BulbState) {
        self.state = state
    }
}

/// Encodes and decodes the Govee LAN UDP JSON protocol.
///
/// Wire formats are taken from
/// the private protocol research notes and the verified
/// probes in `docs/research/probes`. The encoder uses `.sortedKeys` so the bytes are
/// deterministic run to run. Govee bulbs parse the JSON rather than pattern match it,
/// and a sorted-key `colorwc` was verified against a real H6004.
public enum LANMessage {

    // MARK: Wire types

    private struct Envelope<Payload: Encodable>: Encodable {
        struct Message: Encodable {
            var cmd: String
            var data: Payload
        }
        var msg: Message
    }

    private struct DecodeEnvelope<Payload: Decodable>: Decodable {
        struct Message: Decodable {
            var cmd: String
            var data: Payload
        }
        var msg: Message
    }

    private struct CommandProbe: Decodable {
        struct Message: Decodable { var cmd: String }
        var msg: Message
    }

    private struct EmptyData: Encodable {}

    private struct ScanRequestData: Encodable {
        var accountTopic: String
        enum CodingKeys: String, CodingKey { case accountTopic = "account_topic" }
    }

    private struct IntValueData: Encodable {
        var value: Int
    }

    private struct ColorTriple: Codable {
        var r: Int
        var g: Int
        var b: Int
    }

    private struct ColorwcData: Encodable {
        var color: ColorTriple
        var colorTemInKelvin: Int
    }

    private struct StatusWire: Decodable {
        var onOff: Int
        var brightness: Int
        var color: ColorTriple?
        var colorTemInKelvin: Int

        // Swift only synthesizes `CodingKeys` for a `Decodable`-only type when it also
        // synthesizes `init(from:)`. This type writes its own, so the keys are explicit.
        private enum CodingKeys: String, CodingKey {
            case onOff
            case brightness
            case color
            case colorTemInKelvin
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            onOff = try container.decodeIfPresent(Int.self, forKey: .onOff) ?? 0
            brightness = try container.decodeIfPresent(Int.self, forKey: .brightness) ?? 0
            color = try container.decodeIfPresent(ColorTriple.self, forKey: .color)
            colorTemInKelvin = try container.decodeIfPresent(Int.self, forKey: .colorTemInKelvin) ?? 0
        }
    }

    // MARK: Coders

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func encode<Payload: Encodable>(cmd: String, data: Payload) throws -> Data {
        try encoder.encode(Envelope(msg: .init(cmd: cmd, data: data)))
    }

    private static func channel(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }

    // MARK: Requests

    /// Multicast to 239.255.255.250:4001, replies arrive on 4002.
    public static func scanRequest() throws -> Data {
        try encode(cmd: "scan", data: ScanRequestData(accountTopic: "reserve"))
    }

    /// Unicast to bulb-ip:4003, reply arrives on 4002.
    public static func devStatusRequest() throws -> Data {
        try encode(cmd: "devStatus", data: EmptyData())
    }

    public static func turn(on: Bool) throws -> Data {
        try encode(cmd: "turn", data: IntValueData(value: on ? 1 : 0))
    }

    /// H6004 takes 0 through 100. Values outside that range are clamped.
    public static func brightness(_ value: Int) throws -> Data {
        try encode(cmd: "brightness", data: IntValueData(value: min(100, max(0, value))))
    }

    public static func colorwc(rgb: GoveeRGB) throws -> Data {
        let color = ColorTriple(r: Int(rgb.r), g: Int(rgb.g), b: Int(rgb.b))
        return try encode(cmd: "colorwc", data: ColorwcData(color: color, colorTemInKelvin: 0))
    }

    /// White mode. Govee sends a zeroed color alongside the Kelvin value.
    public static func colorwc(kelvin: Int) throws -> Data {
        let color = ColorTriple(r: 0, g: 0, b: 0)
        return try encode(cmd: "colorwc",
                          data: ColorwcData(color: color, colorTemInKelvin: max(0, kelvin)))
    }

    // MARK: Replies

    public static func decode(_ data: Data) -> LANReply? {
        guard let probe = try? decoder.decode(CommandProbe.self, from: data) else { return nil }
        switch probe.msg.cmd {
        case "scan":
            guard let envelope = try? decoder.decode(DecodeEnvelope<ScanReply>.self, from: data) else {
                return nil
            }
            return .scan(envelope.msg.data)
        case "devStatus":
            guard let envelope = try? decoder.decode(DecodeEnvelope<StatusWire>.self, from: data) else {
                return nil
            }
            let wire = envelope.msg.data
            let triple = wire.color ?? ColorTriple(r: 0, g: 0, b: 0)
            let state = BulbState(isOn: wire.onOff != 0,
                                  brightness: min(100, max(0, wire.brightness)),
                                  color: GoveeRGB(r: channel(triple.r),
                                                  g: channel(triple.g),
                                                  b: channel(triple.b)),
                                  colorTemperatureKelvin: wire.colorTemInKelvin)
            return .status(StatusReply(state: state))
        default:
            return nil
        }
    }
}
