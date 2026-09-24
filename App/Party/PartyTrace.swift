import Foundation
import GoveeLAN

/// Makes a Party Mode trace session when the user has asked for one, and nothing otherwise.
///
/// Off unless `defaults write com.philwoolley.glowbeat partyTrace -bool true` is set. The
/// question is asked once per session, when Party Mode starts, so a session with the key
/// off creates no file, installs no observer and changes nothing the engine sends.
///
/// Why it exists: "smooth" is a claim about a real room, and the room is the one place the
/// offline replays and the fake bulbs cannot reach. A trace records what the engine
/// decided on every tick, what actually left the Mac, what the bulbs said back, and every
/// command anything else sent while Party Mode was on.
struct PartyTraceFactory: Sendable {

    static let defaultsKey = "partyTrace"

    /// Asked once per session.
    let isEnabled: @Sendable () -> Bool
    /// Where the CSV files go.
    let directory: URL
    /// The app's one LAN socket, watched for outbound datagrams and bulb status replies.
    /// Nil leaves those two parts of the trace out.
    let socket: LANSocket?
    /// How long a stopped session keeps listening. See `PartyTraceSession.defaultLinger`.
    let linger: TimeInterval

    init(isEnabled: @escaping @Sendable () -> Bool,
         directory: URL,
         socket: LANSocket?,
         linger: TimeInterval = PartyTraceSession.defaultLinger) {
        self.isEnabled = isEnabled
        self.directory = directory
        self.socket = socket
        self.linger = max(0, linger)
    }

    /// `~/Library/Logs/Glowbeat`, gated on the defaults key.
    static func live(socket: LANSocket) -> PartyTraceFactory {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Glowbeat", isDirectory: true)
        return PartyTraceFactory(isEnabled: { UserDefaults.standard.bool(forKey: defaultsKey) },
                                 directory: directory,
                                 socket: socket)
    }

    /// A new session, or nil when tracing is off.
    func makeSession(bulbs: [Bulb], settings: String) -> PartyTraceSession? {
        guard isEnabled() else { return nil }
        return PartyTraceSession(directory: directory, socket: socket, bulbs: bulbs,
                                 settings: settings, linger: linger)
    }
}

/// One Party Mode session's trace file.
///
/// Every method may be called from any thread. The work, formatting included, happens on
/// one private utility queue and reaches the disk once a second, so the main thread only
/// ever pays for copying a few numbers into a struct.
///
/// Row types, one CSV with one header:
/// - `start`, `bulbs`, `event`: the session's settings, the bulb order, and every live
///   change (a slider, a pause, a resume, the stop).
/// - `tick`: one per engine tick. `dt_ms` since the previous tick, frames drained, the
///   gate's loudness and state, low band beats, then for each bulb its intensity, the
///   color the engine rendered and what happened to it: `sent`, `held` (the rate limiter
///   kept it back), `dedup` (too close to the last color sent), with `+rel` when a color
///   held earlier went out on this tick's flush.
/// - `cmd`: every one shot command and every repeat `BulbController` sends while the
///   session is open. Party Mode itself sends only its `brightness 100` as it starts or
///   resumes (and to a bulb that joins mid session), with that command's repeats, until it
///   stops, so any other `cmd` row before the `stop` event is something else driving the
///   bulbs.
/// - `status`: every `devStatus` reply. `age_ms` and `sends_ago` locate the most recent
///   color sent to that bulb within `statusTolerance` of what it reported, which is how
///   far behind the stream the bulb is running. `none` means no color in the history
///   matches, and `distance` then says how close the nearest one came.
/// - `net`: once a second, every datagram that left the socket, by command, with send
///   failures, the largest burst inside 10 ms, and how many replies came back.
/// - `neterr`: a datagram `sendto` refused, with its `errno`.
final class PartyTraceSession: @unchecked Sendable {

    /// What the engine knows at the moment it ticks. Built on the main actor, formatted
    /// on the trace queue.
    struct Tick: Sendable {
        var wall: Date
        var uptime: TimeInterval
        var dtMilliseconds: Double?
        var workMilliseconds: Double
        var frames: Int
        var loudness: Float
        var isOpen: Bool
        var lowBeats: Int
        var beats: Int
        var bulbIDs: [String]
        var intensities: [Double]
        var colors: [GoveeRGB]
        /// The bulbs whose color got past the deduper and was handed to the controller.
        var submitted: Set<String>
    }

    /// The per channel slack a reported color is matched with. The same number the phone
    /// takeover check used on 2026-09-23 (`ExternalChangeDetector.colorTolerance`),
    /// repeated here rather than referenced so the two can change independently; the
    /// nearest distance is logged either way, so any tolerance can be applied afterwards.
    static let statusTolerance = 8
    /// How much send history a status reply is matched against.
    static let historySeconds: TimeInterval = 30
    /// How long a stopped session keeps listening, so the settle color, anything the
    /// light mode sends once Party Mode lets go, and those commands' repeats (one and two
    /// seconds later) are all seen.
    static let defaultLinger: TimeInterval = 2.5

    let fileURL: URL
    private let linger: TimeInterval

    private let queue = DispatchQueue(label: "com.philwoolley.glowbeat.partytrace", qos: .utility)
    private let socket: LANSocket?

    // Everything below is touched on `queue` only.
    private var handle: FileHandle?
    private var buffer = ""
    private var bulbs: [Bulb]
    private var history: [String: [(uptime: TimeInterval, color: GoveeRGB)]] = [:]
    private var lastHeld: [String: GoveeRGB] = [:]
    private var timer: DispatchSourceTimer?
    private var isClosed = false
    private var net = NetCounters()

    // Set by `attach`, read by `finish`. Guarded by `tokenLock`, not the queue, because
    // they are written from the engine's command chain.
    private let tokenLock = NSLock()
    private var commandToken: UUID?
    private var sendToken: UUID?
    private var listener: Task<Void, Never>?

    private struct NetCounters {
        var byCommand: [String: Int] = [:]
        var failures = 0
        var lastErrno: Int32 = 0
        var bytes = 0
        var sendTimes: [TimeInterval] = []
        var replies = 0
    }

    private static let header = ["type", "wall", "uptime_s", "dt_ms", "work_ms", "frames",
                                 "loudness", "gate_open", "low_beats", "beats", "bulb", "rgb",
                                 "age_ms", "sends_ago", "distance", "detail"]

    init(directory: URL, socket: LANSocket?, bulbs: [Bulb], settings: String, linger: TimeInterval) {
        let start = Date()
        self.fileURL = Self.uniqueFileURL(in: directory, at: start)
        self.linger = linger
        self.socket = socket
        self.bulbs = bulbs
        let columns = bulbs.indices.flatMap { index in
            ["b\(index + 1)_intensity", "b\(index + 1)_rgb", "b\(index + 1)_out"]
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let bulbList = Self.bulbList(bulbs)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: fileURL)
            } catch {
                isClosed = true
                return
            }
            append((Self.header + columns).joined(separator: ","))
            append(row("start", start, uptime, detail: settings))
            append(row("bulbs", start, uptime, bulb: "\(bulbs.count)", detail: bulbList))
            flush()
        }
        startTimer()
        startListening()
    }

    deinit {
        timer?.cancel()
        listener?.cancel()
    }

    // MARK: Attaching

    /// Installs the controller and socket observers. Run on the engine's command chain,
    /// so it lands before the first tick's colors do.
    func attach(to controller: BulbController) async {
        let command = await controller.addCommandObserver { [weak self] event in
            self?.command(event)
        }
        let send = socket?.addSendObserver { [weak self] payload, endpoint, failure in
            self?.datagram(payload, to: endpoint, failure: failure)
        }
        storeTokens(command: command, send: send)
    }

    /// Logs the stop, keeps listening for `linger` seconds, then takes the observers out
    /// and closes the file. An observer a newer session installed in the meantime stays.
    func finish(reason: String, controller: BulbController) {
        event("stop", detail: reason)
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            let (command, send) = takeTokens()
            if let command {
                await controller.removeCommandObserver(command)
            }
            if let send {
                socket?.removeSendObserver(send)
            }
            close()
        }
    }

    private func storeTokens(command: UUID, send: UUID?) {
        tokenLock.lock()
        commandToken = command
        sendToken = send
        tokenLock.unlock()
    }

    private func takeTokens() -> (command: UUID?, send: UUID?) {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        let tokens = (commandToken, sendToken)
        commandToken = nil
        sendToken = nil
        return tokens
    }

    // MARK: Recording

    func event(_ name: String, detail: String) {
        let wall = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            append(row(name, wall, uptime, detail: detail))
        }
    }

    func updateBulbs(_ newBulbs: [Bulb]) {
        let wall = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            bulbs = newBulbs
            append(row("bulbs", wall, uptime, bulb: "\(newBulbs.count)", detail: Self.bulbList(newBulbs)))
        }
    }

    /// One tick, once the controller has said which colors went out and which it held.
    func recordTick(_ tick: Tick, wired: Set<String>, released: [String]) {
        queue.async { [self] in
            var fields = [
                "tick", Self.wallString(tick.wall), Self.uptimeString(tick.uptime),
                tick.dtMilliseconds.map { String(format: "%.1f", $0) } ?? "",
                String(format: "%.2f", tick.workMilliseconds),
                "\(tick.frames)", String(format: "%.3f", tick.loudness), tick.isOpen ? "1" : "0",
                "\(tick.lowBeats)", "\(tick.beats)", "", "", "", "", "", "",
            ]
            let releasedSet = Set(released)
            for (index, id) in tick.bulbIDs.enumerated() {
                let color = index < tick.colors.count ? tick.colors[index] : GoveeRGB.black
                let intensity = index < tick.intensities.count ? tick.intensities[index] : 0
                var outcome: String
                if !tick.submitted.contains(id) {
                    outcome = "dedup"
                } else if wired.contains(id) {
                    outcome = "sent"
                    remember(color, for: id, at: tick.uptime)
                } else {
                    outcome = "held"
                    lastHeld[id] = color
                }
                if releasedSet.contains(id), let heldColor = lastHeld[id] {
                    outcome += "+rel"
                    remember(heldColor, for: id, at: tick.uptime)
                    lastHeld[id] = nil
                }
                fields += [String(format: "%.3f", intensity), Self.hex(color), outcome]
            }
            append(fields.joined(separator: ","))
        }
    }

    // MARK: Observers

    private func command(_ event: BulbCommandEvent) {
        let wall = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            switch event {
            case .power(let on, let ids):
                append(row("cmd", wall, uptime, bulb: "\(ids.count)", detail: "power \(on ? "on" : "off")"))
            case .brightness(let value, let ids):
                append(row("cmd", wall, uptime, bulb: "\(ids.count)", detail: "brightness \(value)"))
            case .color(let color, let ids):
                for id in ids { remember(color, for: id, at: uptime) }
                append(row("cmd", wall, uptime, bulb: "\(ids.count)", rgb: Self.hex(color), detail: "color"))
            case .colorTemperature(let kelvin, let ids):
                // The controller files a Kelvin under black, and so does the bulb's report.
                for id in ids { remember(.black, for: id, at: uptime) }
                append(row("cmd", wall, uptime, bulb: "\(ids.count)", detail: "kelvin \(kelvin)"))
            case .repeated(let kind, let id):
                append(row("cmd", wall, uptime, bulb: id, detail: "repeat \(kind.rawValue)"))
            }
        }
    }

    private func datagram(_ payload: Data, to endpoint: LANEndpoint, failure: Int32?) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let wall = Date()
        queue.async { [self] in
            let command = Self.commandName(payload)
            net.byCommand[command, default: 0] += 1
            net.bytes += payload.count
            net.sendTimes.append(uptime)
            if let failure {
                net.failures += 1
                net.lastErrno = failure
                append(row("neterr", wall, uptime, bulb: endpoint.host,
                           detail: "errno \(failure) \(command)"))
            }
        }
    }

    private func startListening() {
        guard let socket else { return }
        // Made here rather than inside the task, so no reply between now and the task's
        // first run is missed.
        let replies = socket.makeDatagramStream()
        listener = Task.detached(priority: .utility) { [weak self] in
            for await datagram in replies {
                guard case .status(let reply)? = LANMessage.decode(datagram.payload) else { continue }
                self?.status(from: datagram.source, state: reply.state)
            }
        }
    }

    private func status(from source: LANEndpoint, state: BulbState) {
        let wall = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            net.replies += 1
            let id = bulbs.first { $0.endpoint == source }?.id
                ?? bulbs.first { $0.endpoint.host == source.host }?.id
                ?? source.host
            let entries = history[id] ?? []
            var age = "none"
            var sendsAgo = ""
            var distance = ""
            if let matchIndex = entries.lastIndex(where: {
                $0.color.channelDistance(to: state.color) <= Self.statusTolerance
            }) {
                age = String(format: "%.0f", (uptime - entries[matchIndex].uptime) * 1000)
                sendsAgo = "\(entries.count - 1 - matchIndex)"
                distance = "\(entries[matchIndex].color.channelDistance(to: state.color))"
            } else if let nearest = entries.enumerated().min(by: {
                $0.element.color.channelDistance(to: state.color) < $1.element.color.channelDistance(to: state.color)
            }) {
                distance = "\(nearest.element.color.channelDistance(to: state.color))"
                sendsAgo = "nearest \(entries.count - 1 - nearest.offset)"
            }
            append(row("status", wall, uptime, bulb: id, rgb: Self.hex(state.color),
                       age: age, sendsAgo: sendsAgo, distance: distance,
                       detail: "on \(state.isOn ? 1 : 0) brightness \(state.brightness) kelvin \(state.colorTemperatureKelvin)"))
        }
    }

    // MARK: Queue only

    private func remember(_ color: GoveeRGB, for id: String, at uptime: TimeInterval) {
        var entries = history[id] ?? []
        entries.append((uptime, color))
        if let first = entries.first, uptime - first.uptime > Self.historySeconds {
            entries.removeAll { uptime - $0.uptime > Self.historySeconds }
        }
        history[id] = entries
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            self?.writeNetRow()
            self?.flush()
        }
        timer = source
        source.resume()
    }

    private func writeNetRow() {
        guard !isClosed else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        var burst = 0
        var start = 0
        let times = net.sendTimes
        for end in times.indices {
            while times[end] - times[start] > 0.010 { start += 1 }
            burst = max(burst, end - start + 1)
        }
        let known = ["colorwc", "devStatus", "turn", "brightness", "scan"]
        var parts = known.map { "\($0) \(net.byCommand[$0] ?? 0)" }
        let other = net.byCommand.filter { !known.contains($0.key) }.values.reduce(0, +)
        parts.append("other \(other)")
        parts.append("total \(times.count)")
        parts.append("failed \(net.failures)")
        if net.failures > 0 { parts.append("errno \(net.lastErrno)") }
        parts.append("bytes \(net.bytes)")
        parts.append("burst10ms \(burst)")
        parts.append("replies \(net.replies)")
        append(row("net", Date(), uptime, detail: parts.joined(separator: " ")))
        net = NetCounters()
    }

    private func append(_ line: String) {
        guard !isClosed else { return }
        buffer += line
        buffer += "\n"
        if buffer.utf8.count > 64 * 1024 {
            flush()
        }
    }

    private func flush() {
        guard let handle, !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        buffer.removeAll(keepingCapacity: true)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            isClosed = true
        }
    }

    private func close() {
        listener?.cancel()
        queue.async { [self] in
            guard !isClosed else { return }
            writeNetRow()
            flush()
            try? handle?.close()
            handle = nil
            isClosed = true
            timer?.cancel()
            timer = nil
        }
    }

    /// Only the tests call this: waits until everything queued so far is on disk.
    func waitUntilWritten() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                flush()
                continuation.resume()
            }
        }
    }

    // MARK: Formatting

    private func row(_ type: String,
                     _ wall: Date,
                     _ uptime: TimeInterval,
                     bulb: String = "",
                     rgb: String = "",
                     age: String = "",
                     sendsAgo: String = "",
                     distance: String = "",
                     detail: String) -> String {
        let clean = detail.replacingOccurrences(of: ",", with: ";")
        return [type, Self.wallString(wall), Self.uptimeString(uptime), "", "", "", "", "", "", "",
                bulb, rgb, age, sendsAgo, distance, clean].joined(separator: ",")
    }

    private static func bulbList(_ bulbs: [Bulb]) -> String {
        bulbs.enumerated().map { "b\($0.offset + 1)=\($0.element.id)" }.joined(separator: " ")
    }

    private static func hex(_ color: GoveeRGB) -> String {
        String(format: "%02X%02X%02X", color.r, color.g, color.b)
    }

    private static func uptimeString(_ uptime: TimeInterval) -> String {
        String(format: "%.3f", uptime)
    }

    private static let wallStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true,
                                                           timeZone: .current)

    private static func wallString(_ date: Date) -> String {
        date.formatted(wallStyle)
    }

    /// The `cmd` of an outbound Govee message, read without decoding the whole thing.
    private static func commandName(_ payload: Data) -> String {
        let text = String(decoding: payload, as: UTF8.self)
        guard let range = text.range(of: "\"cmd\":\"") else { return "unknown" }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "unknown" }
        return String(rest[..<end])
    }

    private static func uniqueFileURL(in directory: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "party-trace-\(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent("\(stem).csv")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).csv")
            suffix += 1
        }
        return candidate
    }
}
