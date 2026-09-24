import XCTest
import AudioTap
import Effects
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The opt-in Party Mode trace: off, it must cost nothing and leave nothing behind; on,
/// it must write what the engine decided, what else reached the bulbs, and what the bulbs
/// said back.
@MainActor
final class PartyTraceTests: XCTestCase {

    private var socket: LANSocket!
    private var fakeBulbs: [FakeBulb] = []
    private var directory: URL!

    private struct Environment {
        var engine: PartyEngine
        var controller: BulbController
        var source: ScriptedFrameSource
        var ticks: ManualTickSource
        var bulbs: [Bulb]
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glowbeat-trace-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeEnvironment(bulbCount: Int, tracing: Bool) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        try socket.start()
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let factory = PartyTraceFactory(isEnabled: { tracing },
                                        directory: directory,
                                        socket: socket,
                                        linger: 0.3)
        let source = ScriptedFrameSource()
        let ticks = ManualTickSource()
        let engine = PartyEngine(controller: controller,
                                 frameSource: source,
                                 tickSource: ticks,
                                 traceFactory: factory)
        let bulbs = fakeBulbs.enumerated().map { index, fake in
            Bulb(id: "AA:0\(index)", sku: "H6004", endpoint: fake.endpoint())
        }
        return Environment(engine: engine, controller: controller, source: source,
                           ticks: ticks, bulbs: bulbs)
    }

    private func start(_ environment: Environment) async throws {
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
    }

    /// Frames in, then ticks with real time between them so the rate limiter lets each
    /// one through.
    private func runTicks(_ environment: Environment, count: Int) async throws {
        environment.source.emitMetronome(frameCount: 60)
        try await Task.sleep(nanoseconds: 250_000_000)
        for _ in 0..<count {
            environment.ticks.fire()
            try await Task.sleep(nanoseconds: 110_000_000)
        }
    }

    private func waitFor(timeout: TimeInterval = 4, _ predicate: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func rows(in url: URL) -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    // MARK: Off

    func testWithTheKeyOffNothingIsWrittenAndNothingIsInstalled() async throws {
        let environment = try makeEnvironment(bulbCount: 2, tracing: false)
        try await start(environment)
        try await runTicks(environment, count: 3)
        await environment.controller.setColorTemperature(kelvin: 2700, bulbs: environment.bulbs)

        XCTAssertFalse(environment.engine.isTracing)
        XCTAssertNil(environment.engine.traceFileURL)
        let observed = await environment.controller.hasCommandObserver
        XCTAssertFalse(observed, "No observer on the controller when tracing is off.")
        XCTAssertFalse(socket.hasSendObserver, "No observer on the socket when tracing is off.")

        environment.engine.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "Tracing off must not even create the log folder.")
        // The session still did its job: the bulbs heard the stream.
        XCTAssertFalse(fakeBulbs[0].recordedCommands().isEmpty)
    }

    // MARK: On

    func testWithTheKeyOnTheTraceRecordsTicksCommandsAndStatusReplies() async throws {
        let environment = try makeEnvironment(bulbCount: 2, tracing: true)
        try await start(environment)
        XCTAssertTrue(environment.engine.isTracing)
        let url = try XCTUnwrap(environment.engine.traceFileURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("party-trace-"))
        XCTAssertEqual(url.pathExtension, "csv")
        await waitFor { await environment.controller.hasCommandObserver }

        try await runTicks(environment, count: 4)
        // Something other than Party Mode reaching for the bulbs mid session.
        await environment.controller.setColorTemperature(kelvin: 2700, bulbs: [environment.bulbs[0]])
        // And the bulbs answering a status poll.
        await environment.controller.requestStatus(bulbs: environment.bulbs)
        try await Task.sleep(nanoseconds: 300_000_000)

        environment.engine.stop()
        XCTAssertFalse(environment.engine.isTracing)
        // The linger, then the observers come out and the file closes.
        await waitFor { !(await environment.controller.hasCommandObserver) && !self.socket.hasSendObserver }
        let stillObserved = await environment.controller.hasCommandObserver
        XCTAssertFalse(stillObserved)
        XCTAssertFalse(socket.hasSendObserver)
        await waitFor { self.rows(in: url).contains { $0.first == "net" } }

        let table = rows(in: url)
        let header = try XCTUnwrap(table.first)
        XCTAssertEqual(Array(header.prefix(4)), ["type", "wall", "uptime_s", "dt_ms"])
        XCTAssertEqual(Array(header.suffix(6)),
                       ["b1_intensity", "b1_rgb", "b1_out", "b2_intensity", "b2_rgb", "b2_out"])
        let types = table.dropFirst().map { $0.first ?? "" }
        XCTAssertEqual(types.first, "start")
        XCTAssertTrue(table.contains { $0.first == "start" && $0.last?.contains("effect pulse") == true })
        XCTAssertTrue(table.contains { $0.first == "bulbs" && $0.last == "b1=AA:00 b2=AA:01" })

        let ticks = table.filter { $0.first == "tick" }
        XCTAssertGreaterThanOrEqual(ticks.count, 3, "One row per tick.")
        for tick in ticks {
            XCTAssertEqual(tick.count, header.count, "Every tick row carries every bulb's columns.")
        }
        let outcomes = ticks.flatMap { [$0[header.count - 4], $0[header.count - 1]] }
        XCTAssertTrue(outcomes.contains("sent"), "The first beat's color goes out.")
        XCTAssertTrue(outcomes.allSatisfy { ["sent", "held", "dedup"].contains($0.replacingOccurrences(of: "+rel", with: "")) })
        XCTAssertTrue(ticks.dropFirst().allSatisfy { Double($0[3]) != nil }, "dt_ms after the first tick.")

        let stopIndex = try XCTUnwrap(table.firstIndex { $0.first == "stop" })
        let kelvin = try XCTUnwrap(table.firstIndex { $0.first == "cmd" && $0.last == "kelvin 2700" })
        XCTAssertLessThan(kelvin, stopIndex, "A non Party command while Party Mode runs is a cmd row before the stop.")
        XCTAssertTrue(table[(stopIndex + 1)...].contains { $0.first == "cmd" && $0.last == "color" },
                      "The settle color on stop is logged after the stop event.")

        let statuses = table.filter { $0.first == "status" }
        let second = try XCTUnwrap(statuses.first { $0[10] == "AA:01" },
                                   "The bulb's reply is matched to its id.")
        XCTAssertNotEqual(second[12], "none", "Its report matches a color the stream sent it.")
        XCTAssertNotNil(Double(second[12]), "age_ms is a number.")
        XCTAssertEqual(second[13], "0", "The most recent color sent is the one it reports.")
        // The other bulb took a Kelvin, which the history files as black the way the
        // controller does; whatever it reports is still located in that history.
        let first = try XCTUnwrap(statuses.first { $0[10] == "AA:00" })
        XCTAssertTrue(Double(first[12]) != nil || first[12] == "none")
        XCTAssertFalse(first[14].isEmpty, "A distance is always given.")

        let net = try XCTUnwrap(table.first { $0.first == "net" })
        XCTAssertTrue(net.last?.contains("colorwc") == true)
        XCTAssertTrue(net.last?.contains("devStatus 2") == true || table.filter { $0.first == "net" }
            .contains { $0.last?.contains("devStatus 2") == true },
                      "The two status polls left the socket.")
    }
}
