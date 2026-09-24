import XCTest
import AudioTap
import Effects
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Reads the colors a fake bulb received. A file scope function so the polling
/// predicates below never have to capture the test case itself.
private func recordedColors(_ bulb: FakeBulb) -> [GoveeRGB] {
    bulb.recordedCommands().compactMap { command in
        if case .color(let rgb) = command { return rgb }
        return nil
    }
}

/// When each color datagram left the socket, and for which port, recorded from the
/// socket's own send observer on whatever queue it calls from.
private final class SendTimes: @unchecked Sendable {
    struct Send {
        var port: UInt16
        var time: TimeInterval
    }

    private let lock = NSLock()
    private var stored: [Send] = []

    func append(port: UInt16, at time: TimeInterval) {
        lock.lock()
        stored.append(Send(port: port, time: time))
        lock.unlock()
    }

    var values: [Send] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Collects the permission updates the engine reports, without capturing the test case
/// in an escaping closure.
@MainActor
private final class PermissionRecorder {
    var values: [AudioTapPermission] = []
}

@MainActor
final class PartyEngineTests: XCTestCase {

    private var socket: LANSocket!
    private var fakeBulbs: [FakeBulb] = []

    private struct Environment {
        var engine: PartyEngine
        var controller: BulbController
        var source: ScriptedFrameSource
        var ticks: ManualTickSource
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
        let source = ScriptedFrameSource()
        let ticks = ManualTickSource()
        let engine = PartyEngine(controller: controller, frameSource: source, tickSource: ticks)
        let bulbs = fakeBulbs.enumerated().map { index, fake in
            Bulb(id: "AA:0\(index)", sku: "H6004", endpoint: fake.endpoint())
        }
        return Environment(engine: engine,
                           controller: controller,
                           source: source,
                           ticks: ticks,
                           bulbs: bulbs)
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
    }

    /// Datagrams cross a real loopback socket, so every positive assertion polls to a
    /// deadline rather than sleeping for a guessed interval.
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

    /// The same deadline poll for state that only the main actor can read.
    private func waitUntilMain(_ predicate: @MainActor () -> Bool,
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

    /// Lets queued frames reach the engine, and gives a send that must NOT happen time
    /// to happen before the test claims it did not.
    private func settle(_ seconds: Double = 0.25) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func startAndBeat(_ environment: Environment,
                              bulbs: [Bulb]? = nil,
                              effect: EffectKind = .pulse) async throws {
        try await environment.engine.start(bulbs: bulbs ?? environment.bulbs,
                                           effect: effect,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()
    }

    func testStartingPutsTheEngineIntoRunning() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.engine.state, .running)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 10)
        XCTAssertTrue(environment.source.isRunning)
    }

    /// The phone takeover detector reads the controller's send history, so Party Mode
    /// must have cleared it by the time `start` returns, not at some later moment.
    func testStartClearsTheSendHistoryBeforeTheFirstTick() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        await environment.controller.setColor(GoveeRGB(r: 1, g: 2, b: 3),
                                              bulbs: environment.bulbs)
        let seeded = await environment.controller.recentSentColors(for: environment.bulbs[0].id)
        XCTAssertFalse(seeded.isEmpty)

        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        let cleared = await environment.controller.recentSentColors(for: environment.bulbs[0].id)
        XCTAssertTrue(cleared.isEmpty, "start must clear the send history before ticking.")
    }

    func testEveryBulbReceivesAColorOnABeat() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        try await startAndBeat(environment)

        for bulb in fakeBulbs {
            let port = bulb.port
            await waitUntil({ !recordedColors(bulb).isEmpty },
                            message: "Bulb \(port) received no color.")
        }
    }

    func testTheLevelMeterFollowsTheAudio() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await startAndBeat(environment)
        XCTAssertGreaterThan(environment.engine.level, 0)
    }

    /// The meter must show the level the gate judges, not the raw frame RMS, or the
    /// marker the user drags would sit on a different scale from the bar it is riding on.
    /// One silent frame after loud audio proves which one is published: the raw RMS is
    /// zero by then and the gate's smoothed level has barely moved.
    func testTheLevelMeterShowsTheSmoothedLevelTheGateJudges() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        emitLoudSteady(environment.source, frameCount: 50, startTime: 0)
        try await settle()
        environment.ticks.fire()
        XCTAssertGreaterThan(environment.engine.level, 0.9, "Loud audio must fill the meter.")

        environment.source.emit(AudioTap.AudioFrame(time: 1, rms: 0, bands: .init(repeating: 0, count: 5)))
        try await settle()
        environment.ticks.fire()
        XCTAssertGreaterThan(environment.engine.level, 0.5,
                             "One silent frame is a raw RMS of zero, but the gate's own "
                                 + "level falls over 300 ms and the meter shows that.")
        XCTAssertLessThan(environment.engine.level, 1)
    }

    func testStoppingSendsTheDimBaseToEveryBulbAndGoesOff() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        try await startAndBeat(environment)
        for bulb in fakeBulbs {
            await waitUntil({ !recordedColors(bulb).isEmpty }, message: "No party color arrived.")
        }

        environment.engine.stop()

        XCTAssertEqual(environment.engine.state, .off)
        XCTAssertFalse(environment.ticks.isRunning)
        let source = environment.source
        await waitUntil({ !source.isRunning }, message: "The tap was never closed.")
        let expected = FrameBridge.goveeColor(from: Palette.party.dimBase)
        for bulb in fakeBulbs {
            let port = bulb.port
            await waitUntil({ recordedColors(bulb).last == expected },
                            message: "Bulb \(port) did not settle at the palette dim base.")
        }
    }

    /// When something else is about to paint the room (the light mode's white, a still
    /// color), the settle color would only flash before it. Stopping without one still
    /// releases what the rate limiter held back, and `pendingCommands` is done once
    /// everything Party Mode queued has gone out, which is what the next owner waits on.
    func testStoppingWithoutASettleSendsNoDimBaseAndSaysWhenItIsDone() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        try await startAndBeat(environment)
        for bulb in fakeBulbs {
            await waitUntil({ !recordedColors(bulb).isEmpty }, message: "No party color arrived.")
        }

        environment.engine.stop(settle: false)
        XCTAssertEqual(environment.engine.state, .off)
        let pending = try XCTUnwrap(environment.engine.pendingCommands)
        await pending.value
        try await settle(0.3)
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        for bulb in fakeBulbs {
            XCTAssertFalse(recordedColors(bulb).contains(dimBase),
                           "The settle color went out though the next owner is about to paint.")
        }
    }

    func testPauseStopsSendingAndResumeStartsAgain() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await startAndBeat(environment)
        await waitUntil({ !recordedColors(fake).isEmpty }, message: "No party color arrived.")

        environment.engine.pause(reason: "Paused: test")
        XCTAssertEqual(environment.engine.state, .paused(reason: "Paused: test"))
        fake.clearRecordedCommands()

        environment.source.emitMetronome(frameCount: 60, startTime: 2)
        try await settle()
        environment.ticks.fire(4)
        try await settle()
        XCTAssertTrue(recordedColors(fake).isEmpty, "A paused engine must send nothing.")

        await environment.engine.resume()
        XCTAssertEqual(environment.engine.state, .running)
        environment.source.emitMetronome(frameCount: 60, startTime: 4)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(fake).isEmpty },
                        message: "A resumed engine must send again.")
    }

    func testSilenceSendsAtMostOneColorBecauseOfDeduping() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.source.emitSilence(frameCount: 100)
        try await settle()
        environment.ticks.fire(6)
        try await settle(0.5)
        XCTAssertLessThanOrEqual(recordedColors(fake).count, 1)
    }

    func testChangingTheEffectResetsTheColorHistorySoTheNextTickSends() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        XCTAssertEqual(fakeBulbs.count, 3)
        try await startAndBeat(environment)
        let fake = fakeBulbs[0]
        await waitUntil({ !recordedColors(fake).isEmpty }, message: "No party color arrived.")

        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        environment.engine.setEffect(.spread)
        environment.source.emitMetronome(frameCount: 60, startTime: 2)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(fake).isEmpty },
                        message: "A new effect must send on the next tick.")
    }

    func testUpdateBulbsChangesHowManyColorsAreProduced() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        let selected = fakeBulbs[0]
        let added = fakeBulbs[1]
        try await startAndBeat(environment, bulbs: [environment.bulbs[0]])
        await waitUntil({ !recordedColors(selected).isEmpty },
                        message: "The selected bulb received no color.")
        try await settle()
        XCTAssertTrue(recordedColors(added).isEmpty, "An unselected bulb must receive nothing.")

        environment.engine.updateBulbs(environment.bulbs)
        environment.source.emitMetronome(frameCount: 60, startTime: 2)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(added).isEmpty },
                        message: "A newly selected bulb must receive a color.")
    }

    /// The reader that pulls from `frameSource.frames` must outlive a session. Cancelling
    /// a task parked in `AsyncStream.next()` finishes that stream for good, and the tap
    /// hands out one stream for its whole life, so canceling on stop would leave Party
    /// Mode working exactly once per launch.
    func testPartyModeStillReceivesFramesAfterAStopAndAnotherStart() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await startAndBeat(environment)
        await waitUntil({ !recordedColors(fake).isEmpty }, message: "No party color arrived.")

        environment.engine.stop()
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        await waitUntil({ recordedColors(fake).last == dimBase },
                        message: "The engine did not settle before the restart.")
        fake.clearRecordedCommands()

        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60, startTime: 4)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(fake).isEmpty },
                        message: "The second session received no frames.")
    }

    /// `stop` has to win when it lands while `start` is suspended awaiting the controller,
    /// or the engine ends up running with a tap the user already switched off.
    func testStoppingWhileStartIsSuspendedLeavesTheEngineOff() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        let engine = environment.engine
        let bulbs = environment.bulbs
        let startTask = Task {
            try await engine.start(bulbs: bulbs,
                                   effect: .pulse,
                                   palette: .party,
                                   gate: 0,
                                   floor: 0,
                                   ceiling: 1,
                                   updatesPerSecond: 10)
        }
        await Task.yield()
        environment.engine.stop()
        try await startTask.value

        XCTAssertEqual(environment.engine.state, .off)
        XCTAssertFalse(environment.ticks.isRunning)
        let source = environment.source
        await waitUntil({ !source.isRunning }, message: "The tap was never closed.")
    }

    /// The same window in `resume`. A zombie running engine here would tick against a tap
    /// that is no longer feeding it.
    func testStoppingWhileResumeIsSuspendedLeavesTheEngineOff() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        let engine = environment.engine
        try await startAndBeat(environment)
        environment.engine.pause(reason: "Paused: test")

        let resumeTask = Task { await engine.resume() }
        await Task.yield()
        environment.engine.stop()
        await resumeTask.value

        XCTAssertEqual(environment.engine.state, .off)
        XCTAssertFalse(environment.ticks.isRunning)
        let source = environment.source
        await waitUntil({ !source.isRunning }, message: "The tap was never closed.")
    }

    /// A phone takeover detected while Party Mode is still starting must not be lost. The
    /// engine finishes starting, so the tap is live, then pauses.
    func testPausingWhileStartIsSuspendedEndsUpPaused() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        let engine = environment.engine
        let bulbs = environment.bulbs
        let startTask = Task {
            try await engine.start(bulbs: bulbs,
                                   effect: .pulse,
                                   palette: .party,
                                   gate: 0,
                                   floor: 0,
                                   ceiling: 1,
                                   updatesPerSecond: 10)
        }
        await Task.yield()
        environment.engine.pause(reason: "Paused: test")
        try await startTask.value

        XCTAssertEqual(environment.engine.state, .paused(reason: "Paused: test"))
        XCTAssertFalse(environment.ticks.isRunning)
        XCTAssertTrue(environment.source.isRunning, "The tap stays live so Resume is instant.")
    }

    /// Silence is a normal thing for a Mac to be playing, so a denied or silent tap is
    /// reported and nothing more. The UI decides whether to explain it.
    func testPermissionUpdatesAreReportedWithoutStoppingTheEngine() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        let engine = environment.engine
        let recorder = PermissionRecorder()
        engine.onPermissionChange = { permission in
            recorder.values.append(permission)
        }

        try await engine.start(bulbs: environment.bulbs,
                               effect: .pulse,
                               palette: .party,
                               gate: 0,
                               floor: 0,
                               ceiling: 1,
                               updatesPerSecond: 10)
        await waitUntilMain({ engine.permission == .granted },
                            message: "The granted update never arrived.")

        environment.source.emitPermission(.deniedOrSilent)
        await waitUntilMain({ engine.permission == .deniedOrSilent },
                            message: "The denied or silent update never arrived.")
        XCTAssertEqual(recorder.values, [.granted, .deniedOrSilent])
        XCTAssertEqual(engine.state, .running, "A silent tap must not switch Party Mode off.")
    }

    // MARK: The party gate

    /// Frames whose overall level sits under the gate but whose bass band still bursts.
    /// Auto-gain scales the bands and the RMS against separate peaks, so this is the
    /// shape of a quiet passage the beat detector would otherwise light the room up for:
    /// exactly what the gate exists to suppress.
    private func emitQuietBeats(_ source: ScriptedFrameSource,
                                frameCount: Int,
                                startTime: TimeInterval) {
        for index in 0..<frameCount {
            let isBurst = index >= 25 && index % 25 <= 1
            source.emit(AudioTap.AudioFrame(time: startTime + Double(index) / 50,
                                            rms: 0.001,
                                            bands: [0.05, isBurst ? 0.9 : 0.1, 0.05, 0.05, 0.05]))
        }
    }

    /// Loud frames with a steady bass band: the gate opens, the detector finds nothing.
    private func emitLoudSteady(_ source: ScriptedFrameSource,
                                frameCount: Int,
                                startTime: TimeInterval) {
        for index in 0..<frameCount {
            source.emit(AudioTap.AudioFrame(time: startTime + Double(index) / 50,
                                            rms: 1,
                                            bands: [0.05, 0.1, 0.05, 0.05, 0.05]))
        }
    }

    /// Loud frames ending in one bass burst: the gate is open and one beat lands.
    private func emitLoudBeat(_ source: ScriptedFrameSource,
                              frameCount: Int,
                              startTime: TimeInterval) {
        for index in 0..<frameCount {
            let isBurst = index >= frameCount - 2
            source.emit(AudioTap.AudioFrame(time: startTime + Double(index) / 50,
                                            rms: 1,
                                            bands: [0.05, isBurst ? 0.9 : 0.1, 0.05, 0.05, 0.05]))
        }
    }

    /// Below the gate every bulb is calm, which is the Darkest end of the range and not
    /// black: someone who keeps the room lit at 30 percent stays lit through a quiet
    /// passage.
    /// The marker is the whole reaction control, so the beat detector has to move with it
    /// on a start and on every drag, with no second setter anywhere.
    func testTheGateCarriesTheBeatSensitivityWithIt() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.3,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.engine.beatSensitivity, 0.7, accuracy: 0.0001,
                       "A start has to take the sensitivity from the gate it was given.")

        environment.engine.setGate(0.8)
        XCTAssertEqual(environment.engine.beatSensitivity, 0.2, accuracy: 0.0001,
                       "Dragging the marker up must make the room pickier, live.")

        environment.engine.setGate(1)
        XCTAssertEqual(environment.engine.beatSensitivity, 0.1, accuracy: 0.0001)
        environment.engine.setGate(0)
        XCTAssertEqual(environment.engine.beatSensitivity, 0.95, accuracy: 0.0001)
        environment.engine.stop()
    }

    /// Always react opens the gate however the marker is set, and pins the beat detector
    /// rather than letting a grayed marker quietly mean "loosest detector".
    func testAlwaysReactOpensTheGateAndPinsTheDetector() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.8,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           alwaysReacts: true)
        XCTAssertTrue(environment.engine.alwaysReacts)
        XCTAssertEqual(environment.engine.gateMarker, 0.8, accuracy: 0.0001,
                       "The marker the user set is kept, it is only not used.")
        XCTAssertEqual(environment.engine.effectiveGate, 0, accuracy: 0.0001,
                       "Always react runs the gate wide open.")
        XCTAssertEqual(environment.engine.beatSensitivity,
                       GlowbeatSettings.alwaysReactsSensitivity, accuracy: 0.0001,
                       "A grayed marker must not mean the loosest detector.")
        environment.engine.stop()
    }

    /// Ticking and unticking the box mid session is live, restarts nothing, and a drag
    /// while it is ticked is remembered without being applied.
    func testDraggingTheMarkerWhileAlwaysReactIsOnChangesNothingUntilItIsOff() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.15,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertFalse(environment.engine.alwaysReacts)
        XCTAssertEqual(environment.engine.effectiveGate, 0.15, accuracy: 0.0001)
        let timing = environment.engine.effectTiming

        environment.engine.setAlwaysReacts(true)
        XCTAssertEqual(environment.engine.effectiveGate, 0, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.beatSensitivity,
                       GlowbeatSettings.alwaysReactsSensitivity, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.state, .running,
                       "Ticking the box must not restart the session.")
        XCTAssertEqual(environment.engine.effectTiming.attack, timing.attack, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.effectTiming.release, timing.release, accuracy: 0.0001)

        environment.engine.setGate(0.6)
        XCTAssertEqual(environment.engine.gateMarker, 0.6, accuracy: 0.0001,
                       "A drag while the box is ticked is still remembered.")
        XCTAssertEqual(environment.engine.effectiveGate, 0, accuracy: 0.0001,
                       "A drag while the box is ticked must change nothing.")
        XCTAssertEqual(environment.engine.beatSensitivity,
                       GlowbeatSettings.alwaysReactsSensitivity, accuracy: 0.0001)

        environment.engine.setAlwaysReacts(false)
        XCTAssertEqual(environment.engine.effectiveGate, 0.6, accuracy: 0.0001,
                       "Unticking the box restores the marker, wherever it was left.")
        XCTAssertEqual(environment.engine.beatSensitivity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.state, .running)
        environment.engine.stop()
    }

    /// The mirror of the test below it: the same quiet music under the same marker, with
    /// Always react on, has to light the room instead of resting at Darkest.
    func testAlwaysReactLightsTheRoomThroughAMarkerThatWouldQuietIt() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.5,
                                           floor: 0.3,
                                           ceiling: 0.6,
                                           updatesPerSecond: 10,
                                           alwaysReacts: true)
        emitQuietBeats(environment.source, frameCount: 150, startTime: 0)
        try await settle()
        environment.ticks.fire(3)
        try await settle(0.5)

        let darkest = FrameBridge.goveeColor(from: Palette.party.colors[0].scaled(by: 0.3))
        for bulb in fakeBulbs {
            let port = bulb.port
            await waitUntil({ recordedColors(bulb).contains { $0 != darkest } },
                            message: "Bulb \(port) stayed dim with Always react on.")
        }
        // The bar has to keep moving while the marker beside it is grayed.
        XCTAssertGreaterThan(environment.engine.level, 0,
                             "The level meter must keep publishing.")
        environment.engine.stop()
    }

    func testBelowTheGateEveryBulbSitsAtTheDarkestEndOfTheRange() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.5,
                                           floor: 0.3,
                                           ceiling: 0.6,
                                           updatesPerSecond: 10)
        emitQuietBeats(environment.source, frameCount: 150, startTime: 0)
        try await settle()
        environment.ticks.fire(3)
        try await settle(0.5)

        // No beat has reached the effect, so Pulse is still on the palette's first color.
        let darkest = FrameBridge.goveeColor(from: Palette.party.colors[0].scaled(by: 0.3))
        for bulb in fakeBulbs {
            let port = bulb.port
            let colors = recordedColors(bulb)
            XCTAssertFalse(colors.isEmpty, "Bulb \(port) received nothing at all.")
            XCTAssertEqual(Set(colors), [darkest], "Bulb \(port) lit up below the gate.")
        }
    }

    /// The whole point of the range: a beat lands between Darkest and Brightest, never
    /// above it and never at black.
    func testABeatLandsInsideTheBrightnessRange() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0.3,
                                           ceiling: 0.6,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()

        let darkest = FrameBridge.goveeColor(from: Palette.party.colors[0].scaled(by: 0.3))
        let brightest = FrameBridge.goveeColor(from: Palette.party.colors[0].scaled(by: 0.6))
        await waitUntil({ recordedColors(fake).contains(brightest) },
                        message: "A beat must reach the Brightest end of the range.")
        let colors = recordedColors(fake)
        for color in colors {
            XCTAssertGreaterThanOrEqual(Int(color.r), Int(darkest.r),
                                        "No bulb may go below Darkest.")
            XCTAssertLessThanOrEqual(Int(color.r), Int(brightest.r),
                                     "No bulb may go above Brightest.")
        }
    }

    /// Dragging Darkest or Brightest during a session has to change the room on the next
    /// tick, with no restart.
    func testChangingTheRangeDuringASessionTakesEffectOnTheNextTick() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0.1,
                                           ceiling: 0.2,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()
        let dim = FrameBridge.goveeColor(from: Palette.party.colors[0].scaled(by: 0.2))
        await waitUntil({ recordedColors(fake).contains(dim) },
                        message: "The first beat must land at the range it started with.")

        environment.engine.setBrightnessRange(floor: 0.5, ceiling: 1)
        fake.clearRecordedCommands()
        environment.source.emitMetronome(frameCount: 60, startTime: 2)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ recordedColors(fake).contains { Int($0.r) > Int(dim.r) } },
                        message: "A raised range must brighten the room without a restart.")
    }

    /// Below the gate the beats are dropped rather than merely painted over, so the
    /// palette has not walked on while the room was quiet. Pulse advances its cursor on
    /// every low beat and the first advance of a session shows the palette's first color,
    /// so gated beats would be visible here as a color further along.
    func testNoBeatsReachTheEffectBelowTheGate() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        // Snap at the top, so the beat that gets through lands on the palette color
        // exactly: this test reads the color to find out which beats reached the effect.
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.5,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           snap: 1)

        // Five bass beats while the room is too quiet for the gate.
        emitQuietBeats(environment.source, frameCount: 150, startTime: 0)
        try await settle()
        environment.ticks.fire()

        // Now it is loud, but nothing is happening in the bass.
        emitLoudSteady(environment.source, frameCount: 50, startTime: 3)
        try await settle()
        environment.ticks.fire()

        // One beat, with the gate open.
        emitLoudBeat(environment.source, frameCount: 50, startTime: 4)
        try await settle()
        environment.ticks.fire()

        let expected = FrameBridge.goveeColor(from: Palette.party.colors[0])
        await waitUntil({ recordedColors(fake).last == expected },
                        message: "The first beat after the gate opened must show the "
                            + "palette's first color, not one the gated beats walked to.")
    }

    func testAboveTheGateTheEffectRunsAsBefore() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.15,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()

        let calm = GoveeRGB(r: 0, g: 0, b: 0)
        await waitUntil({ recordedColors(fake).contains { $0 != calm } },
                        message: "Loud music above the gate must still light the room.")
    }

    /// The gate is live: dragging the marker up during a session has to quiet the room
    /// without a restart.
    func testRaisingTheGateDuringASessionQuietsTheRoom() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()
        // The range this session runs in starts at a floor of zero, so calm is black.
        let calm = GoveeRGB(r: 0, g: 0, b: 0)
        await waitUntil({ recordedColors(fake).contains { $0 != calm } },
                        message: "No party color arrived before the gate was raised.")

        environment.engine.setGate(0.5)
        fake.clearRecordedCommands()
        emitQuietBeats(environment.source, frameCount: 150, startTime: 2)
        try await settle()
        environment.ticks.fire()
        // The room glides down over the Fade (Punchy's 0.3 s here) rather than landing on
        // calm in one tick, so give it longer than that before the last tick.
        try await settle(0.5)
        environment.ticks.fire()
        try await settle(0.5)

        let colors = recordedColors(fake)
        XCTAssertFalse(colors.isEmpty, "The bulb was never told to go dim.")
        XCTAssertEqual(colors.last, calm,
                       "A raised gate must quiet the room without a restart.")
        for (earlier, later) in zip(colors, colors.dropFirst()) {
            XCTAssertLessThanOrEqual(Int(later.r), Int(earlier.r),
                                     "Nothing may brighten once the gate has shut.")
        }
    }

    /// Phil's call on 2026-09-23: when the music drops below Trigger Level the room glides
    /// to calm over the Fade instead of snapping there in one tick. A two second Fade, so
    /// the first tick after the gate shuts is plainly part way down.
    func testClosingTheGateGlidesTheRoomDownRatherThanSnapping() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        XCTAssertEqual(fakeBulbs.count, 1)
        let fake = fakeBulbs[0]
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0.5,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           snap: 1,
                                           fade: EffectTiming.fade(forRelease: 2))
        // The metronome opens the gate and, once its first burst has set the bass band's
        // peak, lands a beat at 1 s, the way the brightness range tests light the room.
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()
        let full = FrameBridge.goveeColor(from: Palette.party.colors[0])
        await waitUntil({ recordedColors(fake).last == full },
                        message: "The beat above the gate never lit the room.")

        fake.clearRecordedCommands()
        emitQuietBeats(environment.source, frameCount: 150, startTime: 2)
        try await settle(0.2)
        environment.ticks.fire()
        let calm = GoveeRGB(r: 0, g: 0, b: 0)
        await waitUntil({ !recordedColors(fake).isEmpty },
                        message: "Nothing was sent on the tick the gate shut.")
        let first = try XCTUnwrap(recordedColors(fake).last)
        XCTAssertNotEqual(first, calm, "The room snapped to calm in one tick.")
        XCTAssertGreaterThan(Int(first.r), Int(full.r) / 2,
                             "A fraction of a second into a two second Fade the room is "
                                 + "still most of the way up.")
        XCTAssertLessThan(Int(first.r), Int(full.r), "The room did not start down at all.")

        try await settle(2.2)
        environment.ticks.fire()
        await waitUntil({ recordedColors(fake).last == calm },
                        message: "The glide never reached calm.")
        environment.engine.stop()
    }

    /// Glow is the effect for music with no drum in it, so the end to end proof is that
    /// volume alone lights the room: these frames never produce a beat.
    func testGlowLightsTheRoomFromVolumeAloneWithNoBeats() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        XCTAssertEqual(fakeBulbs.count, 2)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .glow,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        let calm = GoveeRGB(r: 0, g: 0, b: 0)
        for round in 0..<6 {
            emitLoudSteady(environment.source, frameCount: 25, startTime: Double(round) / 2)
            try await settle(0.1)
            environment.ticks.fire()
        }

        for bulb in fakeBulbs {
            let port = bulb.port
            await waitUntil({ recordedColors(bulb).contains { $0 != calm } },
                            message: "Bulb \(port) stayed dim through loud audio.")
        }
    }

    /// Snap and Fade have to reach the effect that is actually running, not just the
    /// engine's own copy of them. Nothing on screen says which timing an effect holds, so
    /// the wiring is only visible here.
    func testSettingTheTimingReachesTheRunningEffect() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        // `start` defaults Snap and Fade to the app's own, which since 2026-09-14 are
        // Punchy's. They are stored as slider values, so the round trip back to seconds
        // is a hair off the preset's stated times rather than bit for bit equal to them.
        XCTAssertEqual(environment.engine.effectTiming.attack,
                       PartyPreset.punchy.attack, accuracy: 0.0005,
                       "A start has to hand the effect the timing it was given.")
        XCTAssertEqual(environment.engine.effectTiming.release,
                       PartyPreset.punchy.release, accuracy: 0.005)

        environment.engine.setTiming(snap: 0.2, fade: 0.8)
        let dragged = EffectTiming.from(snap: 0.2, fade: 0.8)
        XCTAssertEqual(environment.engine.timing, dragged)
        XCTAssertEqual(environment.engine.effectTiming, dragged,
                       "Dragging Snap or Fade must retune the effect, live.")
        environment.engine.stop()
    }

    /// The bug this covers: `setEffect` builds a brand new effect, which starts on the
    /// shipped timing, so switching from Pulse to Wave mid session silently threw the
    /// user's Snap and Fade away until the next drag.
    func testChangingTheEffectKeepsTheTimingTheUserSet() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setTiming(snap: 0.1, fade: 0.9)
        let chosen = EffectTiming.from(snap: 0.1, fade: 0.9)

        for kind in EffectKind.allCases {
            environment.engine.setEffect(kind)
            XCTAssertEqual(environment.engine.effectTiming, chosen,
                           "\(kind) was built without the user's Snap and Fade.")
        }
        environment.engine.stop()
    }

    /// And `start` takes the two slider values with it, so the first session after a
    /// launch runs on what was saved rather than on the shipped timing.
    func testStartingCarriesTheSnapAndFadeItWasGiven() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .wave,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           snap: 0.35,
                                           fade: 0.7)
        XCTAssertEqual(environment.engine.effectTiming,
                       EffectTiming.from(snap: 0.35, fade: 0.7))
        environment.engine.stop()
    }

    // MARK: Wave travel speed

    /// Travel belongs to one effect, so the engine holds it and hands it to Wave. Nothing
    /// on screen says which speed the running Wave holds, so the wiring is only visible
    /// here.
    func testSettingTheTravelSpeedReachesTheRunningWave() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .wave,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.engine.waveTravelSpeed,
                       WaveEffect.defaultTravelSpeed, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.effectWaveTravelSpeed,
                       WaveEffect.defaultTravelSpeed)

        environment.engine.setWaveTravelSpeed(3)
        XCTAssertEqual(environment.engine.waveTravelSpeed, 3, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.effectWaveTravelSpeed, 3,
                       "Dragging Travel must retune the running Wave, live.")

        environment.engine.setWaveTravelSpeed(99)
        XCTAssertEqual(environment.engine.waveTravelSpeed, 15, accuracy: 0.0001,
                       "The engine holds the speed inside the supported range.")
        environment.engine.stop()
    }

    // MARK: Spread band assignment

    /// The engine holds the assignment by bulb id and lays it out in the room's order
    /// for the effect, which is the only place the two can be seen to agree.
    func testTheSpreadAssignmentReachesTheRunningEffect() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .spread,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.engine.effectSpreadAssignment, [.bass, .mid, .high],
                       "With nothing chosen the room deals itself out round robin.")

        environment.engine.setSpreadAssignments(["AA:00": .high, "AA:02": .bass])
        XCTAssertEqual(environment.engine.effectSpreadAssignment, [.high, .mid, .bass],
                       "A bulb nobody chose for keeps the round robin for its position.")
        environment.engine.stop()
    }

    /// The same bug `effectTiming` and `effectWaveTravelSpeed` cover: `setEffect` builds
    /// a brand new Spread, which starts with no assignment at all, so leaving Spread and
    /// coming back would quietly put every bulb on the band its index happened to give it.
    func testChangingTheEffectKeepsTheSpreadAssignment() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .spread,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setSpreadAssignments(["AA:00": .high, "AA:01": .high, "AA:02": .high])

        for kind in EffectKind.allCases {
            environment.engine.setEffect(kind)
            XCTAssertEqual(environment.engine.spreadAssignments,
                           ["AA:00": .high, "AA:01": .high, "AA:02": .high])
            if kind == .spread {
                XCTAssertEqual(environment.engine.effectSpreadAssignment,
                               [.high, .high, .high],
                               "Spread was rebuilt without the user's choice.")
            } else {
                XCTAssertNil(environment.engine.effectSpreadAssignment)
            }
        }
        environment.engine.stop()
    }

    /// Dragging a bulb up the list must not hand its band to whoever took its slot. The
    /// assignment is keyed on the bulb id, so the ordered array is rebuilt from the new
    /// order rather than staying where it was.
    func testReorderingBulbsRemapsTheSpreadAssignmentByID() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .spread,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setSpreadAssignments(["AA:00": .high, "AA:01": .bass, "AA:02": .mid])
        XCTAssertEqual(environment.engine.effectSpreadAssignment, [.high, .bass, .mid])

        let reversed = Array(environment.bulbs.reversed())
        environment.engine.updateBulbs(reversed)
        XCTAssertEqual(environment.engine.effectSpreadAssignment, [.mid, .bass, .high],
                       "A band belongs to the bulb, not to the slot it was sitting in.")
        environment.engine.stop()
    }

    /// A bulb the assignment has never heard of, which is what a bulb bought today looks
    /// like, takes the round robin for wherever it landed rather than going dark.
    func testANewBulbTakesTheRoundRobinForItsPosition() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .spread,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setSpreadAssignments(["AA:00": .high])
        XCTAssertEqual(environment.engine.effectSpreadAssignment, [.high, .mid, .high])
        environment.engine.stop()
    }

    /// The same bug `effectTiming` covers: `setEffect` builds a brand new Wave, which
    /// starts on the shipped travel speed, so leaving Wave and coming back would throw
    /// the user's Travel away.
    func testChangingTheEffectKeepsTheTravelSpeedTheUserSet() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .wave,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setWaveTravelSpeed(2)

        for kind in EffectKind.allCases {
            environment.engine.setEffect(kind)
            XCTAssertEqual(environment.engine.waveTravelSpeed, 2, accuracy: 0.0001)
            if kind == .wave {
                XCTAssertEqual(environment.engine.effectWaveTravelSpeed, 2,
                               "Wave was rebuilt without the user's Travel.")
            } else {
                XCTAssertNil(environment.engine.effectWaveTravelSpeed,
                             "\(kind) is not a wave and has no travel speed.")
            }
        }
        environment.engine.stop()
    }

    /// And `start` takes the slider value with it, so the first session after a launch
    /// runs on what was saved rather than on the shipped speed.
    func testStartingCarriesTheTravelSpeedItWasGiven() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .wave,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           travelSpeed: 6)
        XCTAssertEqual(environment.engine.waveTravelSpeed, 6, accuracy: 0.0001)
        XCTAssertEqual(environment.engine.effectWaveTravelSpeed, 6)
        environment.engine.stop()
    }

    // MARK: Confetti

    /// Confetti works with every effect, so unlike Travel it reaches whichever one is
    /// running, live, with no restart.
    func testConfettiReachesTheRunningEffectLive() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.engine.effectConfetti, false)
        environment.engine.setConfetti(true)
        XCTAssertTrue(environment.engine.confetti)
        XCTAssertEqual(environment.engine.effectConfetti, true)
        XCTAssertEqual(environment.engine.state, .running, "Turning confetti on restarts nothing.")
        environment.engine.setConfetti(false)
        XCTAssertEqual(environment.engine.effectConfetti, false)
        environment.engine.stop()
    }

    /// A new effect is built from scratch, so switching effect has to hand confetti over
    /// the way it hands over Snap and Fade.
    func testChangingTheEffectKeepsConfetti() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        environment.engine.setConfetti(true)
        for kind in EffectKind.allCases {
            environment.engine.setEffect(kind)
            XCTAssertEqual(environment.engine.effectConfetti, true,
                           "\(kind.displayName) lost confetti.")
        }
        environment.engine.stop()
    }

    func testStartingCarriesConfetti() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .glow,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           confetti: true)
        XCTAssertEqual(environment.engine.effectConfetti, true)
        environment.engine.stop()
    }

    /// End to end: with confetti on, neighbors get different colors on the wire.
    func testConfettiSendsNeighborsDifferentColors() async throws {
        let environment = try makeEnvironment(bulbCount: 3)
        XCTAssertEqual(fakeBulbs.count, 3)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10,
                                           snap: 1,
                                           confetti: true)
        environment.source.emitMetronome(frameCount: 60)
        try await settle()
        environment.ticks.fire()
        let bulbs = fakeBulbs
        await waitUntil({ bulbs.allSatisfy { !recordedColors($0).isEmpty } },
                        message: "Not every bulb received a color.")
        let colors = bulbs.map { recordedColors($0).last }
        XCTAssertNotEqual(colors[0], colors[1])
        XCTAssertNotEqual(colors[1], colors[2])
        environment.engine.stop()
    }

    func testUpdatesPerSecondIsClampedToTheSupportedRange() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 99)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 10)
        environment.engine.setUpdatesPerSecond(1)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 2)
    }

    // MARK: The bulbs' own brightness

    /// A fake bulb dimmed to 30 percent, the way the Colors pane or the All bulbs slider
    /// leaves a real one.
    private func dim(_ fake: FakeBulb, to brightness: Int = 30) {
        fake.applyExternalChange(BulbState(isOn: true,
                                           brightness: brightness,
                                           color: GoveeRGB(r: 200, g: 120, b: 40),
                                           colorTemperatureKelvin: 0))
    }

    /// Where in what a fake bulb heard the full brightness command and the first color
    /// are, with nil for one it never heard.
    private func fullBrightnessAndFirstColor(_ fake: FakeBulb) -> (brightness: Int?, color: Int?) {
        let commands = fake.recordedCommands()
        return (commands.firstIndex(of: .brightness(100)),
                commands.firstIndex { if case .color = $0 { return true }; return false })
    }

    /// Party Mode does its dimming in the colors it sends, Darkest to Brightest, and that
    /// only means what it says on a bulb whose own brightness is 100. A bulb the Colors
    /// pane left at 30 percent used to run the whole session at 30 percent of Brightest.
    func testStartingSetsEveryBulbToFullBrightnessBeforeItsFirstColor() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        fakeBulbs.forEach { dim($0) }
        try await startAndBeat(environment)

        for fake in fakeBulbs {
            let port = fake.port
            await waitUntil({ !recordedColors(fake).isEmpty && fake.currentState().brightness == 100 },
                            message: "Bulb \(port) was not put on full brightness and a color.")
            let order = fullBrightnessAndFirstColor(fake)
            let brightness = try XCTUnwrap(order.brightness)
            let color = try XCTUnwrap(order.color)
            XCTAssertLessThan(brightness, color, "The brightness goes out before the first color.")
        }

        // Stopping settles the color and leaves the brightness alone.
        environment.engine.stop()
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        for fake in fakeBulbs {
            await waitUntil({ recordedColors(fake).last == dimBase }, message: "No settle color.")
            let brightnesses = fake.recordedCommands().filter {
                if case .brightness = $0 { return true }
                return false
            }
            XCTAssertEqual(brightnesses, [.brightness(100)], "Stop must not restore a brightness.")
        }
    }

    /// Whatever the phone did to the brightness while Party Mode was paused, a Resume is
    /// the user asking for Party Mode again, so it goes back to 100 first.
    func testResumingSetsFullBrightnessAgainBeforeTheFirstColor() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        let fake = fakeBulbs[0]
        try await startAndBeat(environment)
        await waitUntil({ !recordedColors(fake).isEmpty }, message: "No party color arrived.")

        environment.engine.pause(reason: "Paused: test")
        try await settle()
        dim(fake, to: 40)
        fake.clearRecordedCommands()

        await environment.engine.resume()
        environment.source.emitMetronome(frameCount: 60, startTime: 4)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(fake).isEmpty && fake.currentState().brightness == 100 },
                        message: "A resumed session must put the bulb back on full brightness.")
        let order = fullBrightnessAndFirstColor(fake)
        XCTAssertLessThan(try XCTUnwrap(order.brightness), try XCTUnwrap(order.color))
    }

    /// A bulb that comes back on the network mid session, off a smart switch at its own
    /// stored brightness, joins at 100 like the rest. The bulbs already playing are not
    /// sent it again.
    func testABulbJoiningMidSessionIsSetToFullBrightnessToo() async throws {
        let environment = try makeEnvironment(bulbCount: 2)
        let playing = fakeBulbs[0]
        let joining = fakeBulbs[1]
        dim(joining)
        try await startAndBeat(environment, bulbs: [environment.bulbs[0]])
        await waitUntil({ !recordedColors(playing).isEmpty }, message: "No party color arrived.")

        environment.engine.updateBulbs(environment.bulbs)
        environment.source.emitMetronome(frameCount: 60, startTime: 2)
        try await settle()
        environment.ticks.fire()
        await waitUntil({ !recordedColors(joining).isEmpty && joining.currentState().brightness == 100 },
                        message: "The joining bulb was not put on full brightness.")
        let order = fullBrightnessAndFirstColor(joining)
        XCTAssertLessThan(try XCTUnwrap(order.brightness), try XCTUnwrap(order.color))
        XCTAssertEqual(playing.recordedCommands().filter { $0 == .brightness(100) }.count, 1)
        environment.engine.stop()
    }

    // MARK: The room's send budget

    /// Waits for the controller's stream rate to settle on `expected`. It is set through
    /// the engine's command chain, so it lands a moment after the call that asked for it.
    private func waitForStreamRate(_ controller: BulbController,
                                   _ expected: Int,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        var rate = await controller.maxStreamedSendsPerSecond
        while rate != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            rate = await controller.maxStreamedSendsPerSecond
        }
        XCTAssertEqual(rate, expected, "The controller streams at the wrong rate.",
                       file: file, line: line)
    }

    /// Ten bulbs at the default ceiling of ten would be a hundred datagrams a second. The
    /// room budget of sixty makes it six each, and the engine ticks at that rate too, so
    /// it never computes colors the rate limiter would only throw away.
    func testTheEngineTicksAtTheRoomsPerBulbRate() async throws {
        let environment = try makeEnvironment(bulbCount: 10)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 6)
        XCTAssertEqual(environment.engine.streamRate, 6)
        await waitForStreamRate(environment.controller, 6)
        environment.engine.stop()
    }

    /// A bulb arriving or leaving mid session changes the room, so the rate is worked out
    /// again on the spot, and the tick follows it without a restart.
    func testTheRateFollowsTheRoomAsBulbsComeAndGo() async throws {
        let environment = try makeEnvironment(bulbCount: 10)
        let six = Array(environment.bulbs.prefix(6))
        try await environment.engine.start(bulbs: six,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 10)
        await waitForStreamRate(environment.controller, 10)

        environment.engine.updateBulbs(environment.bulbs)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 6)
        XCTAssertTrue(environment.ticks.isRunning)
        await waitForStreamRate(environment.controller, 6)

        environment.engine.updateBulbs(six)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 10)
        await waitForStreamRate(environment.controller, 10)
        XCTAssertEqual(environment.engine.state, .running, "A new rate is not a restart.")
        environment.engine.stop()
    }

    /// The Settings slider is the most a bulb may be sent, not the rate: a small room
    /// still runs at what the user chose, and a big one lowers it further.
    func testTheSettingsCeilingIsHonoredBelowTheBudget() async throws {
        let environment = try makeEnvironment(bulbCount: 10)
        let six = Array(environment.bulbs.prefix(6))
        try await environment.engine.start(bulbs: six,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 4)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 4)
        await waitForStreamRate(environment.controller, 4)

        environment.engine.setUpdatesPerSecond(8)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 8)
        await waitForStreamRate(environment.controller, 8)

        environment.engine.updateBulbs(environment.bulbs)
        XCTAssertEqual(environment.ticks.ticksPerSecond, 6, "Ten bulbs lower an eight to six.")
        await waitForStreamRate(environment.controller, 6)
        environment.engine.stop()
    }

    /// Every bulb's color used to leave inside the same few milliseconds, ten datagrams
    /// in one burst every tick. Each bulb now goes at its own slot, about twenty
    /// milliseconds across the room, in the room's order, and all of it inside the tick.
    func testOneTicksSendsAreSpreadAcrossAboutTwentyMilliseconds() async throws {
        let environment = try makeEnvironment(bulbCount: 10)
        let ports = environment.bulbs.map(\.endpoint.port)
        let sends = SendTimes()
        socket.addSendObserver { payload, endpoint, _ in
            guard String(decoding: payload, as: UTF8.self).contains("colorwc") else { return }
            sends.append(port: endpoint.port, at: ProcessInfo.processInfo.systemUptime)
        }
        try await startAndBeat(environment)
        await waitUntil({ sends.values.count >= 10 }, message: "Not every bulb was sent a color.")

        let first = try XCTUnwrap(sends.values.first)
        let last = try XCTUnwrap(sends.values.last)
        XCTAssertEqual(sends.values.map(\.port), ports, "The room's order is the send order.")
        XCTAssertGreaterThanOrEqual(last.time - first.time, 0.015,
                                    "Ten bulbs two milliseconds apart span eighteen.")
        XCTAssertLessThan(last.time - first.time, 1.0 / 6,
                          "One tick's colors must all go inside that tick.")
        // A burst is a few hundredths of a millisecond between datagrams. Spread, the
        // gap is a slot, two milliseconds, and never under half a slot even when a sleep
        // wakes late and the bulbs behind it catch up. The median rather than every gap,
        // because these are timed on the socket's own queue, which can hold one datagram
        // a fraction of a millisecond and close the gap to the next one for reasons that
        // have nothing to do with the engine.
        let gaps = zip(sends.values, sends.values.dropFirst()).map { $1.time - $0.time }.sorted()
        XCTAssertGreaterThanOrEqual(gaps[gaps.count / 2], 0.0008,
                                    "The bulbs went out in one burst: \(gaps).")
        environment.engine.stop()
    }

    /// Building a Core Audio tap takes tens of milliseconds and `AudioDeviceStart` can
    /// block behind the system audio recording prompt, so none of it may happen on the
    /// main actor. The engine still ends up running once the tap is open.
    func testTheAudioTapIsOpenedOffTheMainThread() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        environment.source.setStartDelay(0.05)

        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)

        XCTAssertEqual(environment.source.startRanOnMainThread, false,
                       "The audio tap was opened on the main thread.")
        XCTAssertTrue(environment.source.isRunning)
        XCTAssertEqual(environment.engine.state, .running)
    }

    /// A feel is four numbers, and all four have to reach the running session: the two
    /// times through the effect's own timing, the two brightnesses through the range the
    /// engine renders every frame against. Nothing on screen shows either, so the wiring
    /// is only visible here.
    func testEveryFeelReachesTheRunningSession() async throws {
        let environment = try makeEnvironment(bulbCount: 1)
        try await environment.engine.start(bulbs: environment.bulbs,
                                           effect: .pulse,
                                           palette: .party,
                                           gate: 0,
                                           floor: 0,
                                           ceiling: 1,
                                           updatesPerSecond: 10)

        for preset in PartyPreset.allCases {
            environment.engine.setBrightnessRange(floor: preset.floor, ceiling: preset.ceiling)
            environment.engine.setTiming(snap: preset.snap, fade: preset.fade)

            XCTAssertEqual(environment.engine.effectTiming.attack, preset.attack,
                           accuracy: 0.0005, "\(preset.displayName) Snap")
            XCTAssertEqual(environment.engine.effectTiming.release, preset.release,
                           accuracy: 0.005, "\(preset.displayName) Fade")
            XCTAssertEqual(environment.engine.renderedBrightnessRange.floor, preset.floor,
                           accuracy: 0.0001, "\(preset.displayName) Darkest")
            XCTAssertEqual(environment.engine.renderedBrightnessRange.ceiling, preset.ceiling,
                           accuracy: 0.0001, "\(preset.displayName) Brightest")
            XCTAssertEqual(environment.engine.state, .running,
                           "Tapping a feel must not restart the session.")
        }
        environment.engine.stop()
    }
}
