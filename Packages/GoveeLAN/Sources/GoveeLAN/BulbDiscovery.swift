import Foundation
import OSLog

/// Sends the Govee multicast scan, collects replies, and maintains the bulb list.
///
/// A bulb that misses `missesBeforeUnreachable` consecutive scans is marked unreachable.
/// Bulbs are never removed, because Wi-Fi drops are common and the user's names and
/// ordering are keyed on the bulb id.
public actor BulbDiscovery {

    /// The shortest rescan interval Settings may ask for. Anything faster is pure
    /// broadcast traffic for no extra information.
    public static let minimumRescanInterval: TimeInterval = 15
    /// The longest rescan interval Settings may ask for. Beyond this a bulb that came
    /// back on the network would look dead for too long.
    public static let maximumRescanInterval: TimeInterval = 300
    /// How long a bulb gets to answer a scan before the round it belongs to can close.
    /// Bulbs answer in well under this on a LAN, so the grace period only ever suppresses
    /// misses that the bulb never had a chance to avoid.
    static let replyWindow: TimeInterval = 0.5
    /// How many times one scan round sends the scan request. UDP multicast on Wi-Fi
    /// drops replies: a single send found 4, 5, 6 and 6 of Phil's six real bulbs across
    /// four runs. Govee's own app repeats every command three times for the same reason.
    static let scanRepeatCount = 3
    /// The gap between the sends of one scan burst.
    static let scanRepeatSpacing: TimeInterval = 0.3

    private let socket: LANSocket
    private let configuration: LANConfiguration
    private let missesBeforeUnreachable: Int
    /// Instance copy of `Self.scanRepeatSpacing`, so tests can run a burst in milliseconds.
    private let scanRepeatSpacing: TimeInterval
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "BulbDiscovery")

    /// Seconds between automatic scans. Actor isolation is the lock on this value, so
    /// callers read it with `await` and change it through `setRescanInterval(_:)`.
    public private(set) var rescanInterval: TimeInterval

    public nonisolated let updates: AsyncStream<[Bulb]>
    private nonisolated let updatesContinuation: AsyncStream<[Bulb]>.Continuation

    private var bulbs: [String: Bulb] = [:]
    private var missCounts: [String: Int] = [:]
    private var seenThisRound: Set<String> = []
    private var receiveTask: Task<Void, Never>?
    private var receiveGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    /// When the open round started sending. A round cannot close before its burst has
    /// finished and the reply window has passed.
    private var roundOpenedAt: Date?

    /// `rescanInterval` is taken as given here, so tests can drive a fast loop. The
    /// Settings-facing `setRescanInterval(_:)` is the one that clamps.
    public init(socket: LANSocket,
                configuration: LANConfiguration = .production,
                rescanInterval: TimeInterval = 60,
                missesBeforeUnreachable: Int = 3,
                scanRepeatSpacing: TimeInterval? = nil) {
        self.socket = socket
        self.configuration = configuration
        self.rescanInterval = rescanInterval
        self.missesBeforeUnreachable = missesBeforeUnreachable
        // Nil means the shipping spacing. The constants stay internal, so the default
        // cannot be spelled in the signature of a public initializer.
        self.scanRepeatSpacing = max(0, scanRepeatSpacing ?? Self.scanRepeatSpacing)
        let (stream, continuation) = AsyncStream<[Bulb]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.updates = stream
        self.updatesContinuation = continuation
    }

    deinit {
        updatesContinuation.finish()
    }

    public func start() {
        guard receiveTask == nil else { return }
        receiveGeneration += 1
        let generation = receiveGeneration
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
        startScanLoop(scanImmediately: true)
    }

    public func stop() {
        receiveTask?.cancel()
        scanTask?.cancel()
        burstTask?.cancel()
        receiveTask = nil
        scanTask = nil
        burstTask = nil
    }

    public func currentBulbs() -> [Bulb] {
        sortedBulbs()
    }

    /// Applies the Settings "rescan interval" choice. The value is clamped to the
    /// supported range, and a running timer picks up the new cadence right away.
    /// Changing the interval does not itself trigger a scan, so dragging a slider in
    /// Settings never floods the network.
    public func setRescanInterval(_ seconds: TimeInterval) {
        let clamped = min(Self.maximumRescanInterval, max(Self.minimumRescanInterval, seconds))
        guard clamped != rescanInterval else { return }
        rescanInterval = clamped
        guard scanTask != nil else { return }
        startScanLoop(scanImmediately: false)
    }

    /// Lets the status poller feed reported state back into the bulb list.
    public func apply(state: BulbState, forBulbID id: String) {
        guard var bulb = bulbs[id] else { return }
        bulb.state = state
        bulb.isReachable = true
        bulb.lastSeen = Date()
        bulbs[id] = bulb
        missCounts[id] = 0
        seenThisRound.insert(id)
        publish()
    }

    /// Closes out the previous round's reachability accounting and starts a new scan round.
    ///
    /// A round sends the scan `scanRepeatCount` times, `scanRepeatSpacing` apart, because
    /// Wi-Fi drops multicast. The whole burst is one round: a bulb that answers any of the
    /// three sends counts as seen, and the round cannot close until the burst has finished
    /// and the reply window has passed. That also means tapping "Scan now" repeatedly
    /// cannot stack misses onto a bulb that has not answered yet.
    ///
    /// A newer `scanNow()` supersedes an in flight burst.
    public func scanNow() {
        // An extra scan inside an open round refreshes the burst but does not start a new
        // round, otherwise rapid calls would keep pushing the round's verdict out forever.
        if closeRoundIfDue() {
            roundOpenedAt = Date()
        }
        burstTask?.cancel()
        burstTask = Task { [weak self] in
            await self?.sendScanBurst()
        }
    }

    // MARK: Internals

    /// Ends the open round when it has been open long enough for replies to arrive,
    /// charging a miss to every bulb that stayed silent through it. Returns true when the
    /// round closed, which is when the caller may open the next one.
    @discardableResult
    private func closeRoundIfDue() -> Bool {
        let now = Date()
        if let openedAt = roundOpenedAt, now.timeIntervalSince(openedAt) < minimumRoundDuration {
            return false
        }

        for id in Array(bulbs.keys) where !seenThisRound.contains(id) {
            let misses = (missCounts[id] ?? 0) + 1
            missCounts[id] = misses
            if misses >= missesBeforeUnreachable, var bulb = bulbs[id], bulb.isReachable {
                bulb.isReachable = false
                bulbs[id] = bulb
            }
        }
        seenThisRound.removeAll()
        publish()
        return true
    }

    /// The burst takes this long to finish, and replies get a window after the last send.
    private var minimumRoundDuration: TimeInterval {
        TimeInterval(Self.scanRepeatCount - 1) * scanRepeatSpacing + Self.replyWindow
    }

    private func sendScanBurst() async {
        for index in 0..<Self.scanRepeatCount {
            if index > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(scanRepeatSpacing * 1_000_000_000))
                } catch {
                    return
                }
            }
            if Task.isCancelled { return }
            sendScanRequest()
        }
    }

    private func sendScanRequest() {
        guard let request = try? LANMessage.scanRequest() else {
            logger.error("Unable to encode the scan request.")
            return
        }
        if configuration.joinsMulticast {
            socket.send(request, to: LANEndpoint(host: configuration.multicastGroup,
                                                 port: configuration.scanPort))
            // Direct probes help when multicast is filtered by the access point.
            for bulb in bulbs.values {
                socket.send(request, to: LANEndpoint(host: bulb.endpoint.host,
                                                     port: configuration.scanPort))
            }
        }
        for target in configuration.extraScanTargets {
            socket.send(request, to: target)
        }
    }

    private func startScanLoop(scanImmediately: Bool) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.scanLoop(scanImmediately: scanImmediately)
        }
    }

    private func scanLoop(scanImmediately: Bool) async {
        if scanImmediately {
            scanNow()
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(rescanInterval * 1_000_000_000))
            } catch {
                return
            }
            scanNow()
        }
    }

    /// Runs until the socket's datagram stream ends or the task is canceled, then clears
    /// `receiveTask` so a later `start()` can arm a fresh loop instead of no-opping.
    private func receiveLoop(generation: Int) async {
        defer { finishReceiveLoop(generation: generation) }
        for await datagram in socket.makeDatagramStream() {
            if Task.isCancelled { return }
            switch LANMessage.decode(datagram.payload) {
            case .scan(let reply)?:
                ingest(reply, from: datagram.source)
            case .status(let reply)?:
                if let id = bulbID(for: datagram.source) {
                    apply(state: reply.state, forBulbID: id)
                }
            case nil:
                continue
            }
        }
    }

    private func finishReceiveLoop(generation: Int) {
        // A newer loop may already have replaced this one, so only the current
        // generation is allowed to clear the handle.
        guard generation == receiveGeneration else { return }
        receiveTask = nil
    }

    private func ingest(_ reply: ScanReply, from source: LANEndpoint) {
        let port: UInt16
        switch configuration.commandPort {
        case .fixed(let fixed):
            port = fixed
        case .matchingReplySource:
            port = source.port
        }
        // A reply whose `ip` is missing or malformed falls back to where the datagram
        // actually came from. Trusting a bad `ip` would put a host on the bulb that every
        // later command broadcasts to, because a malformed address converts to
        // 255.255.255.255.
        let host = LANEndpoint.isValidIPv4(reply.ip) ? reply.ip : source.host
        if !reply.ip.isEmpty, !LANEndpoint.isValidIPv4(reply.ip) {
            logger.warning("A scan reply carried the invalid ip \(reply.ip, privacy: .public). Using the datagram source instead.")
        }
        let endpoint = LANEndpoint(host: host, port: port)
        let now = Date()

        if var existing = bulbs[reply.device] {
            existing.endpoint = endpoint
            if !reply.sku.isEmpty { existing.sku = reply.sku }
            if !reply.bleVersionHard.isEmpty { existing.bleVersionHard = reply.bleVersionHard }
            if !reply.bleVersionSoft.isEmpty { existing.bleVersionSoft = reply.bleVersionSoft }
            if !reply.wifiVersionHard.isEmpty { existing.wifiVersionHard = reply.wifiVersionHard }
            if !reply.wifiVersionSoft.isEmpty { existing.wifiVersionSoft = reply.wifiVersionSoft }
            existing.isReachable = true
            existing.lastSeen = now
            bulbs[reply.device] = existing
        } else {
            bulbs[reply.device] = Bulb(id: reply.device,
                                       sku: reply.sku,
                                       endpoint: endpoint,
                                       bleVersionHard: reply.bleVersionHard,
                                       bleVersionSoft: reply.bleVersionSoft,
                                       wifiVersionHard: reply.wifiVersionHard,
                                       wifiVersionSoft: reply.wifiVersionSoft,
                                       state: nil,
                                       isReachable: true,
                                       lastSeen: now)
        }
        missCounts[reply.device] = 0
        seenThisRound.insert(reply.device)
        publish()
    }

    private func bulbID(for source: LANEndpoint) -> String? {
        switch configuration.commandPort {
        case .fixed:
            return bulbs.first { $0.value.endpoint.host == source.host }?.key
        case .matchingReplySource:
            return bulbs.first { $0.value.endpoint == source }?.key
        }
    }

    private func sortedBulbs() -> [Bulb] {
        bulbs.values.sorted { $0.id < $1.id }
    }

    private func publish() {
        updatesContinuation.yield(sortedBulbs())
    }
}
