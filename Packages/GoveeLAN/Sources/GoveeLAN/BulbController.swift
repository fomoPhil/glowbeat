import Foundation
import OSLog

/// Sends commands to bulbs.
///
/// One shot commands from the UI go out `repeatCount` times, `repeatInterval` apart,
/// matching Govee's desktop app (`SEND_CMD_COUNT = 3`, `SEND_CMD_INTERVAL = 1000`),
/// because UDP has no retries. Streamed commands from Party Mode go out once and are
/// coalesced to at most `maxStreamedSendsPerSecond` per bulb.
public actor BulbController {

    public struct Configuration: Sendable {
        public var repeatCount: Int
        public var repeatInterval: TimeInterval
        public var maxStreamedSendsPerSecond: Int
        /// How many of a bulb's latest colors `recentSentColors(for:)` returns, and the
        /// fewest `sentColorHistory(for:asOf:)` ever returns however old they are.
        public var recentColorHistoryCount: Int
        /// How far back, in seconds before a status reply, phone takeover detection looks
        /// for a color the app sent. See `sentColorHistory(for:asOf:)`.
        ///
        /// A count of colors was the wrong bound: at ten sends a second five colors is half
        /// a second of Party Mode, less than one status poll, so a bulb that fell a second
        /// behind on a busy network read as the Govee phone app. Three seconds covers the
        /// H6004's own 0.3 to 1 s fade between colors, a queued or dropped datagram and a
        /// late reply, with room to spare, and is still only a few dozen colors a bulb.
        public var takeoverHistoryWindow: TimeInterval

        public init(repeatCount: Int = 3,
                    repeatInterval: TimeInterval = 1.0,
                    maxStreamedSendsPerSecond: Int = StreamRateLimiter.defaultSendsPerSecond,
                    recentColorHistoryCount: Int = 5,
                    takeoverHistoryWindow: TimeInterval = 3) {
            self.repeatCount = max(1, repeatCount)
            self.repeatInterval = max(0, repeatInterval)
            self.maxStreamedSendsPerSecond = StreamRateLimiter.clampSendsPerSecond(maxStreamedSendsPerSecond)
            self.recentColorHistoryCount = max(1, recentColorHistoryCount)
            self.takeoverHistoryWindow = max(0, takeoverHistoryWindow)
        }
    }

    /// Which command a repeat schedule belongs to. Repeats are canceled per bulb and
    /// per kind, so a new brightness drops the stale brightness retries while an
    /// in-flight power or color command keeps its own.
    ///
    /// A color and a white temperature share one kind on purpose. They are the same
    /// `colorwc` command and the bulb can only be in one of the two modes, so a Kelvin
    /// has to drop a color's pending retries and the other way round. Keeping them apart
    /// let a color picked a second earlier land after the white it was replaced by, and
    /// the bulb jumped back out of white mode on its own.
    private enum CommandKind: Hashable, Sendable {
        case power
        case brightness
        case color
    }

    private struct RepeatKey: Hashable, Sendable {
        var bulbID: String
        var kind: CommandKind
    }

    private struct RepeatSlot: Sendable {
        var generation: UUID
        var task: Task<Void, Never>
    }

    private let socket: LANSocket
    private var configuration: Configuration
    private var limiter: StreamRateLimiter
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "BulbController")

    private var repeatTasks: [RepeatKey: RepeatSlot] = [:]
    /// Every color recently sent to each bulb, stamped with when it went out.
    private var sentColors: [String: SentColorHistory] = [:]
    private var lastBrightness: [String: Int] = [:]
    private var lastPower: [String: Bool] = [:]
    /// Told about every one shot command and every repeat, as it goes out. Nil unless a
    /// diagnostic trace is running, so an ordinary session pays one nil check per command.
    private var commandObserver: (@Sendable (BulbCommandEvent) -> Void)?
    /// Which installation `commandObserver` came from, so an observer that has been
    /// replaced cannot be removed by its old owner.
    private var commandObserverToken: UUID?

    public init(socket: LANSocket, configuration: Configuration = Configuration()) {
        self.socket = socket
        self.configuration = configuration
        self.limiter = StreamRateLimiter(maxSendsPerSecond: configuration.maxStreamedSendsPerSecond)
    }

    // MARK: One shot commands

    public func turn(_ on: Bool, bulbs: [Bulb]) async {
        guard let payload = encode({ try LANMessage.turn(on: on) }) else { return }
        for bulb in bulbs {
            lastPower[bulb.id] = on
        }
        sendOneShot(payload, kind: .power, to: bulbs)
        commandObserver?(.power(on: on, bulbIDs: bulbs.map(\.id)))
    }

    public func setBrightness(_ value: Int, bulbs: [Bulb]) async {
        let clamped = min(100, max(0, value))
        guard let payload = encode({ try LANMessage.brightness(clamped) }) else { return }
        for bulb in bulbs {
            lastBrightness[bulb.id] = clamped
        }
        sendOneShot(payload, kind: .brightness, to: bulbs)
        commandObserver?(.brightness(clamped, bulbIDs: bulbs.map(\.id)))
    }

    public func setColor(_ rgb: GoveeRGB, bulbs: [Bulb]) async {
        guard let payload = encode({ try LANMessage.colorwc(rgb: rgb) }) else { return }
        for bulb in bulbs {
            record(color: rgb, for: bulb.id)
        }
        sendOneShot(payload, kind: .color, to: bulbs)
        commandObserver?(.color(rgb, bulbIDs: bulbs.map(\.id)))
    }

    public func setColorTemperature(kelvin: Int, bulbs: [Bulb]) async {
        guard let payload = encode({ try LANMessage.colorwc(kelvin: kelvin) }) else { return }
        // `colorwc(kelvin:)` puts r, g, b = 0 on the wire and the bulb reports that
        // black back in `devStatus`, so the send history has to own it. Without this
        // every white mode change looks like someone grabbed the Govee phone app.
        for bulb in bulbs {
            record(color: GoveeRGB(r: 0, g: 0, b: 0), for: bulb.id)
        }
        sendOneShot(payload, kind: .color, to: bulbs)
        commandObserver?(.colorTemperature(kelvin: kelvin, bulbIDs: bulbs.map(\.id)))
    }

    public func requestStatus(bulbs: [Bulb]) {
        guard let payload = encode({ try LANMessage.devStatusRequest() }) else { return }
        for bulb in bulbs {
            socket.send(payload, to: bulb.endpoint)
        }
    }

    // MARK: Streamed commands

    /// Party Mode entry point. At most `maxStreamedSendsPerSecond` reach each bulb.
    ///
    /// `now` is the moment the caller decided to send, not the moment this actor got
    /// around to running. The engine stamps one time per tick and passes it in, so the
    /// hop onto this actor cannot make an on time tick look late or early to the rate
    /// limiter. It defaults to the call site's own clock for every other caller.
    ///
    /// Returns true when the color went on the wire now, false when the rate limiter is
    /// holding it for a later `flushStreamed`. Only the diagnostic trace reads it.
    @discardableResult
    public func streamColor(_ rgb: GoveeRGB, to bulb: Bulb, at now: Date = Date()) -> Bool {
        // The live stream is now the truth for this bulb's color, so any repeat still
        // pending from a one shot color is stale. Without this, switching Party Mode off
        // and straight back on inside two seconds lets the settle color land again a
        // second and two seconds later, on top of the stream.
        cancelColorRepeats(for: bulb.id)
        guard let color = limiter.submit(rgb, for: bulb.id, now: now) else { return false }
        sendStreamed(color, to: bulb)
        return true
    }

    /// Releases any color held back by the rate limiter. Call once per engine tick.
    ///
    /// Returns the ids of the bulbs a held color was released to. Only the diagnostic
    /// trace reads it.
    @discardableResult
    public func flushStreamed(bulbs: [Bulb], at now: Date = Date()) -> [String] {
        let byID = Dictionary(bulbs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var released: [String] = []
        for entry in limiter.drain(now: now) {
            guard let bulb = byID[entry.bulbID] else { continue }
            sendStreamed(entry.color, to: bulb)
            released.append(bulb.id)
        }
        return released
    }

    /// Hands every later one shot command and repeat to `observer`, replacing any
    /// observer already installed. Party Mode's opt-in trace installs one for the length
    /// of a session. Returns the token that removes it.
    @discardableResult
    public func addCommandObserver(_ observer: @escaping @Sendable (BulbCommandEvent) -> Void) -> UUID {
        let token = UUID()
        commandObserver = observer
        commandObserverToken = token
        return token
    }

    /// Removes the observer `token` installed, and nothing else: one installed since then
    /// by somebody else stays.
    public func removeCommandObserver(_ token: UUID) {
        guard commandObserverToken == token else { return }
        commandObserver = nil
        commandObserverToken = nil
    }

    /// Whether an observer is installed. Read by the tests that prove a session with the
    /// trace switched off leaves none behind.
    public var hasCommandObserver: Bool {
        commandObserver != nil
    }

    /// The rate each bulb is streamed at right now: whatever Party Mode or a scene last
    /// set, which for Party Mode is the room's share of the send budget.
    public var maxStreamedSendsPerSecond: Int {
        configuration.maxStreamedSendsPerSecond
    }

    public func setMaxStreamedSendsPerSecond(_ value: Int) {
        let clamped = StreamRateLimiter.clampSendsPerSecond(value)
        configuration.maxStreamedSendsPerSecond = clamped
        limiter.maxSendsPerSecond = clamped
    }

    // MARK: Send history, used by external change detection

    /// The last `recentColorHistoryCount` colors sent to this bulb, oldest first.
    public func recentSentColors(for bulbID: String) -> [GoveeRGB] {
        let entries = sentColors[bulbID]?.entries ?? []
        return entries.suffix(configuration.recentColorHistoryCount).map(\.color)
    }

    /// Every color sent to this bulb that could explain a status reply received at
    /// `time`, oldest first, each with the moment it went out: all of those sent in the
    /// `takeoverHistoryWindow` before `time`, the one the bulb was already showing or
    /// fading from when that window opened, and never fewer than the last
    /// `recentColorHistoryCount`. See `SentColorHistory`.
    public func sentColorHistory(for bulbID: String, asOf time: Date) -> [SentColorHistory.Entry] {
        sentColors[bulbID]?.entries(asOf: time) ?? []
    }

    public func lastSentBrightness(for bulbID: String) -> Int? {
        lastBrightness[bulbID]
    }

    public func lastSentPower(for bulbID: String) -> Bool? {
        lastPower[bulbID]
    }

    /// Forgets everything the app believes it sent. A new Party Mode session calls this
    /// first, so every repeat the previous session scheduled is canceled with it: a
    /// retry that outlived the history it belongs to would reach the bulb with nothing
    /// left to explain it, and takeover detection would read it as a phone.
    public func clearSendHistory() {
        for slot in repeatTasks.values {
            slot.task.cancel()
        }
        repeatTasks.removeAll()
        sentColors.removeAll()
        lastBrightness.removeAll()
        lastPower.removeAll()
        limiter.reset()
    }

    private func cancelColorRepeats(for bulbID: String) {
        let key = RepeatKey(bulbID: bulbID, kind: .color)
        repeatTasks[key]?.task.cancel()
        repeatTasks[key] = nil
    }

    // MARK: Internals

    private func encode(_ build: () throws -> Data) -> Data? {
        do {
            return try build()
        } catch {
            logger.error("Failed to encode a LAN message: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func sendStreamed(_ color: GoveeRGB, to bulb: Bulb) {
        guard let payload = encode({ try LANMessage.colorwc(rgb: color) }) else { return }
        socket.send(payload, to: bulb.endpoint)
        record(color: color, for: bulb.id)
    }

    /// Sends now, then schedules the remaining repeats. Any repeats still pending for
    /// the same bulb and the same kind of command are canceled first: the newest
    /// value is the truth, and a stale retry landing a second later would make the
    /// bulb visibly flick back to the old value.
    private func sendOneShot(_ payload: Data, kind: CommandKind, to bulbs: [Bulb]) {
        for bulb in bulbs {
            let key = RepeatKey(bulbID: bulb.id, kind: kind)
            repeatTasks[key]?.task.cancel()
            repeatTasks[key] = nil
            socket.send(payload, to: bulb.endpoint)
            scheduleRepeats(payload, key: key, endpoint: bulb.endpoint)
        }
    }

    private func scheduleRepeats(_ payload: Data, key: RepeatKey, endpoint: LANEndpoint) {
        let remaining = configuration.repeatCount - 1
        guard remaining > 0 else { return }
        let interval = configuration.repeatInterval
        let generation = UUID()
        let task = Task {
            for _ in 0..<remaining {
                if interval > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        // Superseded by a newer command for this bulb. Never let the
                        // canceled sleep collapse the rest of the schedule into a burst.
                        return
                    }
                }
                if Task.isCancelled { return }
                socket.send(payload, to: endpoint)
                reportRepeat(key)
            }
            finishRepeats(key: key, generation: generation)
        }
        repeatTasks[key] = RepeatSlot(generation: generation, task: task)
    }

    private func reportRepeat(_ key: RepeatKey) {
        guard let commandObserver else { return }
        let kind: BulbCommandEvent.Kind
        switch key.kind {
        case .power: kind = .power
        case .brightness: kind = .brightness
        case .color: kind = .color
        }
        commandObserver(.repeated(kind, bulbID: key.bulbID))
    }

    private func finishRepeats(key: RepeatKey, generation: UUID) {
        guard repeatTasks[key]?.generation == generation else { return }
        repeatTasks[key] = nil
    }

    /// Stamped with the moment it goes out rather than the tick that asked for it, since
    /// the question the history answers is what the bulb had been told by then.
    private func record(color: GoveeRGB, for bulbID: String) {
        var history = sentColors[bulbID]
            ?? SentColorHistory(window: configuration.takeoverHistoryWindow,
                                minimumCount: configuration.recentColorHistoryCount)
        history.record(color, at: Date())
        sentColors[bulbID] = history
    }
}
