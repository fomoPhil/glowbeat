import XCTest
import Effects
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Reads the colors a fake bulb received. A file scope function so the polling
/// predicates never have to capture the test case itself.
private func recordedColors(_ bulb: FakeBulb) -> [GoveeRGB] {
    bulb.recordedCommands().compactMap { command in
        if case .color(let rgb) = command { return rgb }
        return nil
    }
}

private func recordedPower(_ bulb: FakeBulb) -> [Bool] {
    bulb.recordedCommands().compactMap { command in
        if case .turn(let on) = command { return on }
        return nil
    }
}

/// A monotonic clock the test moves by hand, so a twenty minute Sunset takes
/// milliseconds to prove.
@MainActor
private final class ManualClock {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: TimeInterval = 0
    }

    private let box = Box()

    var reader: @Sendable () -> TimeInterval {
        let box = self.box
        return {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.value
        }
    }

    func advance(by seconds: TimeInterval) {
        box.lock.lock()
        box.value += seconds
        box.lock.unlock()
    }
}

@MainActor
final class SceneEngineTests: XCTestCase {

    private var socket: LANSocket!
    private var fakeBulbs: [FakeBulb] = []

    private struct Environment {
        var engine: SceneEngine
        var controller: BulbController
        var ticks: ManualTickSource
        var clock: ManualClock
        var bulbs: [Bulb]
    }

    private func makeEnvironment(bulbCount: Int) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { index in
            try FakeBulb(deviceID: "AA:0\(index)")
        }
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
        let ticks = ManualTickSource()
        let clock = ManualClock()
        let engine = SceneEngine(controller: controller, tickSource: ticks, clock: clock.reader)
        let bulbs = fakeBulbs.enumerated().map { index, fake in
            Bulb(id: "AA:0\(index)", sku: "H6004", endpoint: fake.endpoint())
        }
        return Environment(engine: engine,
                           controller: controller,
                           ticks: ticks,
                           clock: clock,
                           bulbs: bulbs)
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
    }

    /// Datagrams cross a real loopback socket, so every positive assertion polls.
    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool,
                           timeout: TimeInterval = 3,
                           message: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    private func settle(_ seconds: Double = 0.25) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// One scene second, at the rate the engine really ticks.
    private func run(_ environment: Environment, sceneSeconds: TimeInterval) {
        let step = 1.0 / Double(SceneKind.updatesPerSecond)
        var elapsed: TimeInterval = 0
        while elapsed < sceneSeconds {
            environment.clock.advance(by: step)
            environment.ticks.fire()
            elapsed += step
        }
    }

    func testStartingTicksAtFourPerSecondAndReportsTheScene() throws {
        let environment = try makeEnvironment(bulbCount: 1)
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .breathe,
                                 palette: .party,
                                 speed: 1)
        XCTAssertEqual(environment.engine.state, .running(.breathe))
        XCTAssertEqual(environment.engine.state.kind, .breathe)
        XCTAssertTrue(environment.ticks.isRunning)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 4)
        XCTAssertEqual(environment.ticks.ticksPerSecond, SceneKind.updatesPerSecond)
        environment.engine.stop()
    }

    func testEveryBulbReceivesTheSceneColors() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .breathe,
                                 palette: .party,
                                 speed: 1)
        run(environment, sceneSeconds: 3)
        for bulb in fakeBulbs {
            let port = bulb.port
            await waitUntil({ !recordedColors(bulb).isEmpty },
                            message: "Bulb \(port) received no scene color.")
        }
        environment.engine.stop()
    }

    /// Every scene does its brightness in the colors it sends: Breathe's dim base, the
    /// Candle's flicker, Sunset's twenty minutes down. None of that means what it says on
    /// a bulb whose own brightness the Colors pane left at 30 percent, so a scene puts
    /// every bulb on full brightness first, the way Party Mode does.
    func testAScenePutsEveryBulbOnFullBrightnessBeforeItsFirstColor() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        for fake in fakeBulbs {
            fake.applyExternalChange(BulbState(isOn: true, brightness: 30,
                                               color: GoveeRGB(r: 1, g: 2, b: 3),
                                               colorTemperatureKelvin: 0))
        }
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .candle,
                                 palette: .party,
                                 speed: 1)
        run(environment, sceneSeconds: 1)

        for fake in fakeBulbs {
            let port = fake.port
            await waitUntil({ !recordedColors(fake).isEmpty && fake.currentState().brightness == 100 },
                            message: "Bulb \(port) was not put on full brightness and a color.")
            let commands = fake.recordedCommands()
            let brightness = try XCTUnwrap(commands.firstIndex(of: .brightness(100)))
            let color = try XCTUnwrap(commands.firstIndex { if case .color = $0 { return true }; return false })
            XCTAssertLessThan(brightness, color, "The brightness goes out before the first color.")
        }
        environment.engine.stop()
    }

    /// Static holds still, so after the first send there is nothing left to say. The
    /// deduper is what keeps a held scene off the network entirely.
    func testAStillSceneSendsOnceAndThenGoesQuiet() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .fixed,
                                 palette: .party,
                                 speed: 1)
        run(environment, sceneSeconds: 2)
        try await settle(0.5)

        for (index, bulb) in fakeBulbs.enumerated() {
            let colors = recordedColors(bulb)
            XCTAssertEqual(colors.count, 1,
                           "Bulb \(bulb.port) heard a still scene more than once.")
            XCTAssertEqual(colors.first,
                           FrameBridge.goveeColor(from: Palette.party.colors[index]),
                           "Static lays the palette across the bulbs in list order.")
        }
        environment.engine.stop()
    }

    /// The one scene with an end: the bulbs go out and the control goes back to off, with
    /// nothing left ticking.
    func testSunsetEndsWithTheBulbsOffAndTheSceneOff() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .sunset,
                                 palette: .party,
                                 speed: 1)
        environment.clock.advance(by: 0.25)
        environment.ticks.fire()
        XCTAssertEqual(environment.engine.progress ?? -1, 0, accuracy: 0.001)

        environment.clock.advance(by: SunsetScene.duration / 2)
        environment.ticks.fire()
        XCTAssertEqual(environment.engine.progress ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(environment.engine.state, .running(.sunset))

        environment.clock.advance(by: SunsetScene.duration / 2)
        environment.ticks.fire()
        XCTAssertEqual(environment.engine.state, .off, "A finished scene switches itself off.")
        XCTAssertNil(environment.engine.progress)
        XCTAssertFalse(environment.ticks.isRunning)
        await waitUntil({ recordedPower(fake).contains(false) },
                        message: "The bulbs must go out at the end of a sunset.")
    }

    /// Four times speed is four times shorter, which is the whole point of the slider.
    func testSpeedShortensATimedScene() throws {
        let environment = try makeEnvironment(bulbCount: 1)
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .sunset,
                                 palette: .party,
                                 speed: 4)
        environment.clock.advance(by: 0.25)
        environment.ticks.fire()
        environment.clock.advance(by: SunsetScene.duration / 4)
        environment.ticks.fire()
        XCTAssertEqual(environment.engine.state, .off)
    }

    func testStoppingStopsTheClockAndLeavesTheBulbsAlone() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .breathe,
                                 palette: .party,
                                 speed: 1)
        run(environment, sceneSeconds: 3)
        await waitUntil({ !recordedColors(fake).isEmpty }, message: "No scene color arrived.")

        environment.engine.stop()
        XCTAssertEqual(environment.engine.state, .off)
        XCTAssertFalse(environment.ticks.isRunning)
        try await settle(0.4)
        let afterStop = recordedColors(fake).count
        let power = recordedPower(fake)
        try await settle(0.4)
        XCTAssertEqual(recordedColors(fake).count, afterStop,
                       "A stopped scene must stop sending.")
        XCTAssertEqual(power, [], "Stopping a scene must not switch a bulb off.")
    }

    /// Switching scenes mid run starts the new one from its own beginning rather than
    /// dropping into the middle of it.
    func testSwitchingSceneWhileRunningSwapsItLive() throws {
        let environment = try makeEnvironment(bulbCount: 1)
        environment.engine.start(bulbs: environment.bulbs,
                                 kind: .breathe,
                                 palette: .party,
                                 speed: 1)
        run(environment, sceneSeconds: 2)
        environment.engine.setScene(.candle)
        XCTAssertEqual(environment.engine.state, .running(.candle))
        run(environment, sceneSeconds: 1)
        environment.engine.stop()
    }

    /// Picking a scene while nothing is running only changes what would start next.
    func testSettingASceneWhileOffDoesNotStartAnything() {
        let engine = SceneEngine(controller: BulbController(socket: LANSocket(configuration: .production)),
                                 tickSource: ManualTickSource())
        engine.setScene(.candle)
        XCTAssertEqual(engine.state, .off)
    }
}
