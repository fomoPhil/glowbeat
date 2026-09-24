import Foundation

/// One reported state change for one bulb.
public struct BulbStatusUpdate: Hashable, Sendable {
    public var bulbID: String
    public var state: BulbState
    public var receivedAt: Date

    public init(bulbID: String, state: BulbState, receivedAt: Date) {
        self.bulbID = bulbID
        self.state = state
        self.receivedAt = receivedAt
    }
}

/// Sends `devStatus` to every known bulb on an interval and publishes the replies.
///
/// The app uses 1 s while Party Mode runs, stretched past six bulbs so the whole room is
/// asked about six times a second, and 10 s otherwise.
public actor StatusPoller {

    /// The shortest interval the poller will run at. Tests drive it this fast; the app
    /// never asks for anything under 1 s.
    static let minimumInterval: TimeInterval = 0.05

    private let socket: LANSocket
    private let configuration: LANConfiguration
    private var interval: TimeInterval
    private var bulbs: [Bulb] = []
    private var pollTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var receiveGeneration = 0

    public nonisolated let statuses: AsyncStream<BulbStatusUpdate>
    private nonisolated let statusesContinuation: AsyncStream<BulbStatusUpdate>.Continuation

    public init(socket: LANSocket,
                configuration: LANConfiguration = .production,
                interval: TimeInterval = 10) {
        self.socket = socket
        self.configuration = configuration
        self.interval = max(Self.minimumInterval, interval)
        let (stream, continuation) = AsyncStream<BulbStatusUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        self.statuses = stream
        self.statusesContinuation = continuation
    }

    deinit {
        statusesContinuation.finish()
    }

    /// Each loop is armed on its own. The socket ends every datagram stream when it
    /// stops, so a poller that outlives a socket restart needs a later `start(bulbs:)`
    /// to arm a fresh receive loop even though the poll loop is still running.
    public func start(bulbs: [Bulb]) {
        self.bulbs = bulbs
        if receiveTask == nil {
            receiveGeneration += 1
            let generation = receiveGeneration
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(generation: generation)
            }
        }
        if pollTask == nil {
            startPollLoop(pollImmediately: true)
        }
    }

    public func stop() {
        pollTask?.cancel()
        receiveTask?.cancel()
        pollTask = nil
        receiveTask = nil
    }

    public func updateBulbs(_ bulbs: [Bulb]) {
        self.bulbs = bulbs
    }

    /// The cadence in force right now.
    public var pollInterval: TimeInterval {
        interval
    }

    /// Applies a new cadence right away. Party Mode drops 10 s to 1 s on entry, so the
    /// running timer is restarted rather than left to drain, which would otherwise delay
    /// the first fast poll by up to the old interval. The restart deliberately does not
    /// poll immediately, so repeated calls cannot turn into a burst of requests.
    public func setInterval(_ interval: TimeInterval) {
        let clamped = max(Self.minimumInterval, interval)
        guard clamped != self.interval else { return }
        self.interval = clamped
        guard pollTask != nil else { return }
        startPollLoop(pollImmediately: false)
    }

    public func pollNow() {
        guard let payload = try? LANMessage.devStatusRequest() else { return }
        for bulb in bulbs {
            socket.send(payload, to: bulb.endpoint)
        }
    }

    private func startPollLoop(pollImmediately: Bool) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop(pollImmediately: pollImmediately)
        }
    }

    private func pollLoop(pollImmediately: Bool) async {
        if pollImmediately {
            pollNow()
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            pollNow()
        }
    }

    private func receiveLoop(generation: Int) async {
        defer { finishReceiveLoop(generation: generation) }
        for await datagram in socket.makeDatagramStream() {
            if Task.isCancelled { return }
            guard case .status(let reply)? = LANMessage.decode(datagram.payload),
                  let id = bulbID(for: datagram.source) else {
                continue
            }
            statusesContinuation.yield(BulbStatusUpdate(bulbID: id,
                                                        state: reply.state,
                                                        receivedAt: Date()))
        }
    }

    private func finishReceiveLoop(generation: Int) {
        // A newer loop may already have replaced this one, so only the current
        // generation is allowed to clear the handle.
        guard generation == receiveGeneration else { return }
        receiveTask = nil
    }

    private func bulbID(for source: LANEndpoint) -> String? {
        switch configuration.commandPort {
        case .fixed:
            return bulbs.first { $0.endpoint.host == source.host }?.id
        case .matchingReplySource:
            return bulbs.first { $0.endpoint == source }?.id
        }
    }
}
