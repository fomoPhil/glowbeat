import Darwin
import Foundation
import GoveeLAN

/// A test only UDP responder that behaves like an H6004 with LAN Control turned on.
///
/// It binds an ephemeral port on 127.0.0.1, answers `scan` and `devStatus`, applies
/// `turn`, `brightness` and `colorwc`, and records every command it receives. Replies
/// go back to the sender's source address, so a `LANSocket` configured with
/// `commandPort: .matchingReplySource` treats the responder's port as the command port.
public final class FakeBulb: @unchecked Sendable {

    public enum Command: Hashable, Sendable {
        case scan
        case devStatus
        case turn(Bool)
        case brightness(Int)
        case color(GoveeRGB)
        case colorTemperature(Int)
    }

    public enum FakeBulbError: Error, Equatable {
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
    }

    private let deviceID: String
    private let sku: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.philwoolley.glowbeat.fakebulb")

    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var boundPort: UInt16 = 0
    private var state = BulbState(isOn: false,
                                  brightness: 100,
                                  color: GoveeRGB(r: 255, g: 255, b: 255),
                                  colorTemperatureKelvin: 0)
    private var commands: [Command] = []
    private var answersScan = true
    private var appliesBrightness = true
    /// What the scan reply claims its own address is. Real bulbs report a dotted quad;
    /// a test can make one report rubbish to exercise the fallback.
    private var reportedIP = "127.0.0.1"

    public init(deviceID: String, sku: String = "H6004") throws {
        self.deviceID = deviceID
        self.sku = sku

        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard handle >= 0 else { throw FakeBulbError.socketCreationFailed(errno) }

        var reuse: Int32 = 1
        _ = setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(handle, F_SETFL, O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw FakeBulbError.bindFailed(errno)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }

        descriptor = handle
        boundPort = UInt16(bigEndian: actual.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(handle)
        }
        source.setCancelHandler {
            close(handle)
        }
        readSource = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// The ephemeral port this responder is listening on.
    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public func endpoint() -> LANEndpoint {
        LANEndpoint(host: "127.0.0.1", port: port)
    }

    public func stop() {
        lock.lock()
        let source = readSource
        readSource = nil
        descriptor = -1
        boundPort = 0
        lock.unlock()
        source?.cancel()
    }

    public func recordedCommands() -> [Command] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    public func clearRecordedCommands() {
        lock.lock()
        commands.removeAll()
        lock.unlock()
    }

    public func currentState() -> BulbState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Simulates the per bulb LAN Control toggle in Govee Home.
    public func setAnswersScan(_ answers: Bool) {
        lock.lock()
        answersScan = answers
        lock.unlock()
    }

    /// Simulates a bulb that heard a brightness command and has not applied it: a dropped
    /// repeat, or a firmware that is a beat behind. It still records the command.
    public func setAppliesBrightness(_ applies: Bool) {
        lock.lock()
        appliesBrightness = applies
        lock.unlock()
    }

    /// Makes the scan reply claim a different `ip` than the one it answers from.
    public func setReportedIP(_ ip: String) {
        lock.lock()
        reportedIP = ip
        lock.unlock()
    }

    /// Simulates someone changing the bulb from the Govee phone app.
    public func applyExternalChange(_ newState: BulbState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    // MARK: Wire handling

    private func drain(_ descriptorValue: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { storage in
                    storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(descriptorValue, raw.baseAddress, raw.count, 0, address, &fromLength)
                    }
                }
            }
            guard count > 0 else { return }
            respond(to: Data(buffer[0..<count]), from: from, on: descriptorValue)
        }
    }

    private func respond(to request: Data, from source: sockaddr_storage, on descriptorValue: Int32) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let message = object["msg"] as? [String: Any],
              let cmd = message["cmd"] as? String else {
            return
        }
        let data = message["data"] as? [String: Any] ?? [:]

        switch cmd {
        case "scan":
            lock.lock()
            commands.append(.scan)
            let answers = answersScan
            lock.unlock()
            guard answers else { return }
            reply(scanPayload(), to: source, on: descriptorValue)

        case "devStatus":
            lock.lock()
            commands.append(.devStatus)
            let snapshot = state
            lock.unlock()
            reply(statusPayload(snapshot), to: source, on: descriptorValue)

        case "turn":
            let isOn = (data["value"] as? Int ?? 0) != 0
            lock.lock()
            state.isOn = isOn
            commands.append(.turn(isOn))
            lock.unlock()

        case "brightness":
            let value = min(100, max(0, data["value"] as? Int ?? 0))
            lock.lock()
            if appliesBrightness {
                state.brightness = value
            }
            commands.append(.brightness(value))
            lock.unlock()

        case "colorwc":
            let kelvin = data["colorTemInKelvin"] as? Int ?? 0
            let color = data["color"] as? [String: Any] ?? [:]
            let rgb = GoveeRGB(r: Self.channel(color["r"]),
                               g: Self.channel(color["g"]),
                               b: Self.channel(color["b"]))
            lock.lock()
            if kelvin > 0 {
                state.colorTemperatureKelvin = kelvin
                commands.append(.colorTemperature(kelvin))
            } else {
                state.colorTemperatureKelvin = 0
                state.color = rgb
                commands.append(.color(rgb))
            }
            lock.unlock()

        default:
            break
        }
    }

    private static func channel(_ value: Any?) -> UInt8 {
        guard let number = value as? Int else { return 0 }
        return UInt8(min(255, max(0, number)))
    }

    private func scanPayload() -> Data {
        lock.lock()
        let ip = reportedIP
        lock.unlock()
        let body: [String: Any] = [
            "msg": [
                "cmd": "scan",
                "data": [
                    "ip": ip,
                    "device": deviceID,
                    "sku": sku,
                    "bleVersionHard": "3.01.01",
                    "bleVersionSoft": "1.03.01",
                    "wifiVersionHard": "1.00.10",
                    "wifiVersionSoft": "1.01.27"
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func statusPayload(_ snapshot: BulbState) -> Data {
        let body: [String: Any] = [
            "msg": [
                "cmd": "devStatus",
                "data": [
                    "onOff": snapshot.isOn ? 1 : 0,
                    "brightness": snapshot.brightness,
                    "color": [
                        "r": Int(snapshot.color.r),
                        "g": Int(snapshot.color.g),
                        "b": Int(snapshot.color.b)
                    ],
                    "colorTemInKelvin": snapshot.colorTemperatureKelvin
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func reply(_ payload: Data, to source: sockaddr_storage, on descriptorValue: Int32) {
        var destination = source
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptorValue, raw.baseAddress, raw.count, 0, $0, length)
                }
            }
        }
    }
}
