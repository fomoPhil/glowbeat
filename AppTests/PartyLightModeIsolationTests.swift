import XCTest
import AudioTap
import Effects
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Collects the controller's one shot commands from any thread, marked with whether
/// Party Mode was running when each went out.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var partyRunning = false
    private var stored: [(duringParty: Bool, event: BulbCommandEvent)] = []

    func setPartyRunning(_ running: Bool) {
        lock.lock()
        partyRunning = running
        lock.unlock()
    }

    func append(_ event: BulbCommandEvent) {
        lock.lock()
        stored.append((partyRunning, event))
        lock.unlock()
    }

    var duringParty: [BulbCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored.filter(\.duringParty).map(\.event)
    }

    var afterParty: [BulbCommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored.filter { !$0.duringParty }.map(\.event)
    }

    func clear() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
    }
}

/// Smoothness investigation H3, 2026-09-23: "Light mode Auto fights Party."
///
/// Phil runs Auto, which follows Night Shift. If the light mode or the schedule sent a
/// Kelvin, a brightness or a power command while Party Mode streamed, the room would
/// lurch. This runs Party Mode on fake bulbs with Auto on, flips Night Shift in the middle
/// of the session, walks the schedule's thirty second poll, and checks that nothing but
/// Party Mode's own stream reaches the bulbs until Party Mode stops.
@MainActor
final class PartyLightModeIsolationTests: XCTestCase {

    private var socket: LANSocket?
    private var fakeBulbs: [FakeBulb] = []
    private var suiteName = ""

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private struct Environment {
        var model: AppModel
        var controller: BulbController
        var source: ScriptedFrameSource
        var ticks: ManualTickSource
        var scheduleTicker: ManualIntervalTicker
        var clock: ManualDateClock
        var nightShift: FakeNightShift
    }

    private func makeEnvironment(bulbCount: Int, now: Date) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        let socket = LANSocket(configuration: configuration)
        self.socket = socket
        try socket.start()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let source = ScriptedFrameSource()
        let ticks = ManualTickSource()
        let scheduleTicker = ManualIntervalTicker()
        let clock = ManualDateClock(now)
        // Night Shift on its own custom schedule, off at noon.
        let nightShift = FakeNightShift(status: .scripted(enabled: false, mode: .custom))
        let model = AppModel(socket: socket,
                             discovery: BulbDiscovery(socket: socket,
                                                      configuration: configuration,
                                                      rescanInterval: 60,
                                                      missesBeforeUnreachable: 3),
                             controller: controller,
                             poller: StatusPoller(socket: socket, configuration: configuration, interval: 0.2),
                             frameSource: source,
                             tickSource: ticks,
                             sceneTickSource: ManualTickSource(),
                             scheduleTickSource: scheduleTicker,
                             scheduleClock: clock.reader,
                             calendar: try XCTUnwrap(Calendar.gregorianDenver()),
                             nightShift: nightShift,
                             settingsStore: SettingsStore(defaults: defaults),
                             nameStore: BulbNameStore(defaults: defaults),
                             loginItems: FakeLoginItemService())
        model.completeFirstRun()
        return Environment(model: model, controller: controller, source: source, ticks: ticks,
                           scheduleTicker: scheduleTicker, clock: clock, nightShift: nightShift)
    }

    private func waitFor(timeout: TimeInterval = 4, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func nonStreamCommands(_ bulb: FakeBulb) -> [FakeBulb.Command] {
        bulb.recordedCommands().filter { command in
            switch command {
            case .turn, .brightness, .colorTemperature: return true
            case .scan, .devStatus, .color: return false
            }
        }
    }

    /// A tick's worth of music, then a tick, with real time between ticks.
    private func play(_ environment: Environment, ticks: Int, startTime: TimeInterval) async {
        environment.source.emitMetronome(frameCount: ticks * 5 + 25, startTime: startTime)
        try? await Task.sleep(nanoseconds: 150_000_000)
        for _ in 0..<ticks {
            environment.ticks.fire()
            try? await Task.sleep(nanoseconds: 105_000_000)
        }
    }

    func testAutoLightModeSendsNothingWhilePartyModeRunsEvenWhenNightShiftFlips() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16,
                                                                    hour: 12, minute: 0)))
        let environment = try makeEnvironment(bulbCount: 3, now: noon)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        XCTAssertEqual(model.bulbs.count, 3)

        // Phil's setup: the light mode on Auto, the schedule on with wake and sleep far
        // from now, so its thirty second poll runs and reconciles the light mode.
        model.setScheduleEnabled(true)
        model.setLightMode(.auto)
        await waitFor { self.fakeBulbs.allSatisfy { !self.nonStreamCommands($0).isEmpty } }
        let log = CommandLog()
        await environment.controller.addCommandObserver { log.append($0) }
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        log.clear()

        model.setPartyModeEnabled(true)
        await waitFor { model.partyState == .running }
        XCTAssertEqual(model.partyState, .running)
        log.setPartyRunning(true)

        await play(environment, ticks: 10, startTime: 0)

        // Night Shift switches on mid session, by hand, and CoreBrightness says so.
        environment.nightShift.status = .scripted(enabled: true, mode: .custom)
        environment.nightShift.notifyChange()
        // The schedule's poll keeps running through the whole of a thirty minute shift.
        for _ in 0..<8 {
            environment.clock.advance(by: 5 * 60)
            environment.scheduleTicker.fire()
            await play(environment, ticks: 3, startTime: 10)
        }
        await play(environment, ticks: 10, startTime: 20)
        XCTAssertEqual(model.lightModeStatus.isWarm, true, "The light mode did see the flip.")

        // Party Mode's own one shot, its full brightness at the start, is the only one.
        let others = log.duringParty.filter {
            if case .brightness(100, _) = $0 { return false }
            return true
        }
        XCTAssertEqual(others, [],
                       "No one shot command but Party Mode's own while Party Mode streams.")
        for bulb in fakeBulbs {
            XCTAssertEqual(nonStreamCommands(bulb), [.brightness(100)],
                           "No Kelvin, brightness or power but Party Mode's own reached a bulb "
                            + "while Party Mode ran.")
            XCTAssertFalse(bulb.recordedCommands().filter {
                if case .color = $0 { return true }
                return false
            }.isEmpty, "The stream itself did reach the bulb.")
        }

        // Stop, and record what the room hears next.
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        log.setPartyRunning(false)
        model.setPartyModeEnabled(false)
        await waitFor {
            self.fakeBulbs.allSatisfy { bulb in
                bulb.recordedCommands().contains { if case .colorTemperature = $0 { return true }; return false }
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        for bulb in fakeBulbs {
            let after = bulb.recordedCommands().filter { $0 != .devStatus && $0 != .scan }
            let temperatures = after.filter { if case .colorTemperature = $0 { return true }; return false }
            XCTAssertEqual(temperatures, [.colorTemperature(WhiteTemperature.nightKelvin)],
                           "The white worked out during the session is applied once, after it.")
            // The stop race (H3): the settle color used to go down Party Mode's chain and
            // the white down the light mode's, and the settle landed last on every bulb.
            // The light mode has a white to put back, so the settle color, which would
            // only flash before it, is not sent, and the white waits for Party Mode's
            // last command.
            XCTAssertFalse(after.contains(.color(dimBase)),
                           "The settle color went out over the white: \(after)")
            XCTAssertEqual(after.last, .colorTemperature(WhiteTemperature.nightKelvin),
                           "The white is the last thing the bulb hears: \(after)")
            XCTAssertEqual(bulb.currentState().colorTemperatureKelvin, WhiteTemperature.nightKelvin,
                           "The room ends on the light mode's white, not the palette's dim base.")
        }
        XCTAssertEqual(log.afterParty.filter {
            if case .colorTemperature = $0 { return true }
            return false
        }.count, 1, "One Kelvin command, for every bulb at once.")
    }

    // MARK: One ordered stop path

    /// Party Mode running, with music, on three fake bulbs, and a tick fired a moment ago
    /// so its colors are still going out one slot at a time when the test acts.
    private func partyMidTick(_ environment: Environment) async {
        let model = environment.model
        model.setPartyModeEnabled(true)
        await waitFor { model.partyState == .running }
        XCTAssertEqual(model.partyState, .running)
        await play(environment, ticks: 3, startTime: 0)
        environment.source.emitMetronome(frameCount: 30, startTime: 3)
        try? await Task.sleep(nanoseconds: 150_000_000)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        environment.ticks.fire()
    }

    /// The other half of the rule: with no white held back, the room settles on the
    /// palette's dim base, exactly as it always has.
    func testWithNothingHeldBackTheRoomSettlesOnTheDimBase() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16,
                                                                    hour: 12, minute: 0)))
        let environment = try makeEnvironment(bulbCount: 3, now: noon)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        XCTAssertEqual(model.bulbs.count, 3)

        await partyMidTick(environment)
        model.setPartyModeEnabled(false)
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        await waitFor { self.fakeBulbs.allSatisfy { $0.currentState().color == dimBase } }
        try await Task.sleep(nanoseconds: 300_000_000)
        for bulb in fakeBulbs {
            let after = bulb.recordedCommands().filter { $0 != .devStatus && $0 != .scan }
            XCTAssertEqual(after.last, .color(dimBase), "The dim base is the last word: \(after)")
            XCTAssertFalse(after.contains { if case .colorTemperature = $0 { return true }; return false },
                           "Nothing was held back, so there is no white to send.")
        }
    }

    /// The same race had a second loser: a still color picked while Party Mode runs went
    /// out on its own task, and the settle color queued behind Party Mode's last tick
    /// landed on top of it. The pick is what the room ends on.
    func testAColorPickedWhilePartyModeRunsIsWhatTheRoomEndsOn() async throws {
        let calendar = try XCTUnwrap(Calendar.gregorianDenver())
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16,
                                                                    hour: 12, minute: 0)))
        let environment = try makeEnvironment(bulbCount: 3, now: noon)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        XCTAssertEqual(model.bulbs.count, 3)

        await partyMidTick(environment)
        model.applyStillColor(.ocean)
        guard case .rgb(let rgb) = StillColor.ocean.value else {
            return XCTFail("Ocean is an RGB color.")
        }
        let ocean = FrameBridge.goveeColor(from: rgb)
        let dimBase = FrameBridge.goveeColor(from: Palette.party.dimBase)
        await waitFor { self.fakeBulbs.allSatisfy { $0.recordedCommands().contains(.color(ocean)) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        for bulb in fakeBulbs {
            let after = bulb.recordedCommands().filter { $0 != .devStatus && $0 != .scan }
            let picked = try XCTUnwrap(after.lastIndex(of: .color(ocean)), "Ocean never arrived.")
            XCTAssertFalse(after[picked...].contains { if case .color = $0 { return $0 != .color(ocean) }; return false },
                           "A Party Mode color landed after the pick: \(after)")
            XCTAssertFalse(after.contains(.color(dimBase)), "The settle color went out: \(after)")
            XCTAssertEqual(bulb.currentState().color, ocean)
        }
    }
}
