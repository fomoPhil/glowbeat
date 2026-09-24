import SwiftUI
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

/// Everything a fake bulb was told to do, without the scan and status chatter that a
/// running app produces alongside it.
private func controlCommands(_ bulb: FakeBulb) -> [FakeBulb.Command] {
    bulb.recordedCommands().filter { $0 != .scan && $0 != .devStatus }
}

/// How many status polls a fake bulb has answered. It snapshots its state for the reply
/// in the same breath as it records the request, so once this count moves, that poll's
/// answer is fixed and the bulb can be given a new color for the next one.
private func statusPolls(_ bulb: FakeBulb) -> Int {
    bulb.recordedCommands().filter { $0 == .devStatus }.count
}

private let identifyWhite = GoveeRGB(r: 255, g: 255, b: 255)

@MainActor
final class AppModelTests: XCTestCase {

    private var socket: LANSocket!
    /// Every socket a test opened. A relaunch builds a second one on the same fake
    /// bulbs, and both have to be closed however the test ends.
    private var sockets: [LANSocket] = []
    private var fakeBulbs: [FakeBulb] = []
    private var suiteName = ""
    /// The audio clock the streaming helpers hand the engine. Monotonic across a test.
    private var streamTime: TimeInterval = 0
    /// Shared by the model and by the relaunched model, the way one Mac's login item is
    /// shared by both runs of the app. Fake, so the suite never registers a real one.
    private var loginItems = FakeLoginItemService()

    private struct Environment {
        var model: AppModel
        var source: ScriptedFrameSource
        var ticks: ManualTickSource
        /// Scenes run on their own clock, so they get their own hand driven source.
        var sceneTicks: ManualTickSource
        /// The model's own controller, so a test can put exact colors on the wire the way
        /// Party Mode streams them, with no effect or beat detector deciding what they are.
        var controller: BulbController
    }

    private func makeModel(bulbCount: Int,
                           pollInterval: TimeInterval = 0.2,
                           replyPort: UInt16 = 0,
                           startsSocket: Bool = true) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        return try makeEnvironment(pollInterval: pollInterval,
                                   replyPort: replyPort,
                                   startsSocket: startsSocket)
    }

    /// A second `AppModel` over the same defaults suite and the same fake bulbs, which
    /// is what a relaunch looks like from the stores' point of view.
    private func relaunch(pollInterval: TimeInterval = 0.2) throws -> Environment {
        try makeEnvironment(pollInterval: pollInterval, replyPort: 0, startsSocket: true)
    }

    /// The defaults suite both models share. Tests read the stores directly through it
    /// when what they are checking is what was written, not what the model shows.
    private func sharedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func makeEnvironment(pollInterval: TimeInterval,
                                 replyPort: UInt16,
                                 startsSocket: Bool) throws -> Environment {
        let configuration = LANConfiguration(replyPort: replyPort,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        sockets.append(socket)
        if startsSocket {
            try socket.start()
        }

        let defaults = try sharedDefaults()

        let controller = BulbController(socket: socket,
                                        configuration: .init(repeatCount: 1,
                                                             repeatInterval: 0.01,
                                                             maxStreamedSendsPerSecond: 10,
                                                             recentColorHistoryCount: 5))
        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration,
                                      rescanInterval: 60,
                                      missesBeforeUnreachable: 3)
        let poller = StatusPoller(socket: socket,
                                  configuration: configuration,
                                  interval: pollInterval)
        let source = ScriptedFrameSource()
        let ticks = ManualTickSource()
        let sceneTicks = ManualTickSource()
        let model = AppModel(socket: socket,
                             discovery: discovery,
                             controller: controller,
                             poller: poller,
                             frameSource: source,
                             tickSource: ticks,
                             sceneTickSource: sceneTicks,
                             settingsStore: SettingsStore(defaults: defaults),
                             nameStore: BulbNameStore(defaults: defaults),
                             loginItems: loginItems)
        return Environment(model: model,
                           source: source,
                           ticks: ticks,
                           sceneTicks: sceneTicks,
                           controller: controller)
    }

    override func tearDown() async throws {
        for openSocket in sockets { openSocket.stop() }
        sockets = []
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        streamTime = 0
        loginItems = FakeLoginItemService()
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: Polling helpers
    //
    // Everything here crosses a real loopback socket or an asynchronous engine
    // transition, so each wait returns the value it settled on and the test asserts on
    // that value unconditionally.

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func waitForParty(_ model: AppModel,
                              timeout: TimeInterval = 5,
                              matching predicate: (PartyEngine.State) -> Bool) async -> PartyEngine.State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model.partyState) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model.partyState
    }

    private func waitFor(timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Tests

    func testStatusLineAndBannerBeforeAnyBulbIsFound() throws {
        let environment = try makeModel(bulbCount: 0)
        XCTAssertEqual(environment.model.banner, .noBulbs)
        XCTAssertEqual(environment.model.statusLine, "No bulbs found.")
    }

    func testDiscoveryFillsTheBulbListAndTheStatusLine() async throws {
        let environment = try makeModel(bulbCount: 2)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)
        XCTAssertEqual(environment.model.bulbs.count, 2)
        XCTAssertNil(environment.model.banner)
        XCTAssertEqual(environment.model.statusLine, "2 bulbs. Party Mode is off.")
    }

    func testDisplayNamesFallBackToANumberedLabelAndRoundTrip() async throws {
        let environment = try makeModel(bulbCount: 2)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)
        XCTAssertEqual(environment.model.bulbs.count, 2)

        let first = environment.model.bulbs[0]
        XCTAssertEqual(environment.model.displayName(for: first), "Bulb 1")
        environment.model.setDisplayName("Kitchen", for: first)
        XCTAssertEqual(environment.model.displayName(for: first), "Kitchen")
    }

    func testTurningABulbOnReachesTheFakeBulb() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        environment.model.setPower(true, for: environment.model.bulbs[0])
        let bulb = fakeBulbs[0]
        await waitFor(timeout: 3) { bulb.currentState().isOn }
        XCTAssertTrue(bulb.currentState().isOn)
    }

    func testAllBulbsBrightnessReachesEveryFakeBulb() async throws {
        let environment = try makeModel(bulbCount: 2)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)
        XCTAssertEqual(environment.model.bulbs.count, 2)

        environment.model.setBrightness(37, for: nil)
        let bulbs = fakeBulbs
        await waitFor(timeout: 3) { bulbs.allSatisfy { $0.currentState().brightness == 37 } }
        XCTAssertTrue(fakeBulbs.allSatisfy { $0.currentState().brightness == 37 })
    }

    func testTurningPartyModeOnAndOffMovesThroughRunningAndOff() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        environment.model.setPartyModeEnabled(true)
        let running = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(running, .running)
        XCTAssertEqual(environment.model.statusLine, "1 bulb. Listening to system audio.")

        environment.model.setPartyModeEnabled(false)
        let stopped = await waitForParty(environment.model) { $0 == .off }
        XCTAssertEqual(stopped, .off)
    }

    func testAnExternalBrightnessChangePausesPartyModeAndResumeClearsIt() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        // No wait for a poll: Party Mode's baseline is Glowbeat's own last command, so
        // it is enough that the command reached the bulb.
        environment.model.setBrightness(80, for: nil)
        let bulb = fakeBulbs[0]
        await waitFor(timeout: 3) { bulb.currentState().brightness == 80 }
        XCTAssertEqual(bulb.currentState().brightness, 80)

        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)

        // The baseline is the first report of the session, so the session needs one poll
        // before there is anything for a phone change to contradict. Party Mode polls
        // every second.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(environment.model.partyState, .running)

        // Someone moves the brightness slider in Govee Home.
        var changed = fakeBulbs[0].currentState()
        changed.brightness = 12
        fakeBulbs[0].applyExternalChange(changed)

        let paused = await waitForParty(environment.model) {
            if case .paused = $0 { return true }
            return false
        }
        guard case .paused(let reason) = paused else {
            return XCTFail("Party Mode did not pause. State is \(paused).")
        }
        XCTAssertTrue(reason.contains("Govee app"))
        XCTAssertEqual(environment.model.banner, .partyPaused(reason))

        environment.model.resumeParty()
        let resumed = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(resumed, .running)
    }

    func testSettingsChangesPersistThroughTheStore() throws {
        let environment = try makeModel(bulbCount: 0)
        environment.model.setEffect(.wave)
        environment.model.setPalette(id: "ocean")
        environment.model.setMaxUpdatesPerSecond(4)
        environment.model.setRescanInterval(120)
        environment.model.completeFirstRun()

        XCTAssertEqual(environment.model.settings.effectKind, .wave)
        XCTAssertEqual(environment.model.settings.paletteID, "ocean")
        XCTAssertEqual(environment.model.settings.maxUpdatesPerSecond, 4)
        XCTAssertEqual(environment.model.settings.rescanInterval, 120)
        XCTAssertTrue(environment.model.settings.hasCompletedFirstRun)
    }

    /// Travel belongs to Wave alone, so it sits on the Party panel rather than in
    /// Settings, but it is held in range and written through like every other slider.
    func testTheWaveTravelSpeedIsHeldInsideTheSupportedRange() throws {
        let environment = try makeModel(bulbCount: 0)
        let model = environment.model
        XCTAssertEqual(model.settings.waveTravelSpeed,
                       WaveEffect.defaultTravelSpeed, accuracy: 0.0001)

        model.setWaveTravelSpeed(7)
        XCTAssertEqual(model.settings.waveTravelSpeed, 7, accuracy: 0.0001)
        // Live, while the slider is being dragged.
        model.setWaveTravelSpeed(99, persist: false)
        XCTAssertEqual(model.settings.waveTravelSpeed, 15, accuracy: 0.0001)
        model.setWaveTravelSpeed(-1)
        XCTAssertEqual(model.settings.waveTravelSpeed, 1, accuracy: 0.0001)
    }

    /// Always react is a checkbox, not a drag, so it has to reach the store the moment it
    /// is ticked rather than waiting for a release that never comes.
    func testAlwaysReactIsOffOnAFreshInstallAndPersistsTheMomentItIsTicked() throws {
        let environment = try makeModel(bulbCount: 0)
        let model = environment.model
        XCTAssertFalse(model.settings.alwaysReacts,
                       "A fresh install still reacts from the marker.")

        model.setAlwaysReacts(true)
        XCTAssertTrue(model.settings.alwaysReacts)
        XCTAssertTrue(try relaunch().model.settings.alwaysReacts,
                      "Ticking the box has to be written through straight away.")

        model.setAlwaysReacts(false)
        XCTAssertFalse(try relaunch().model.settings.alwaysReacts)
    }

    // MARK: The audio banner is for real trouble, not a pause
    //
    // Phil, 2026-09-22: the tap cannot tell "denied" from "silent", so three seconds of
    // quiet raised "Glowbeat is not hearing any audio, allow the permission" every time a
    // song ended. His ruling: the red banner only for a session that has never heard a
    // thing (or a tap that would not open at all); a session that has heard music and
    // then goes quiet just says "Waiting for music." in the status line.

    /// One bulb found and Party Mode running.
    private func startParty(_ environment: Environment) async {
        environment.model.startServices()
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)
        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)
    }

    /// What `SystemAudioTap` reports after three seconds of nothing, and the model
    /// hearing it.
    private func goQuiet(_ environment: Environment) async {
        let model = environment.model
        environment.source.emitPermission(.deniedOrSilent)
        await waitFor(timeout: 3) { model.audioPermission == .deniedOrSilent }
        XCTAssertEqual(model.audioPermission, .deniedOrSilent)
    }

    private func waitForMusic(_ model: AppModel) async {
        await waitFor(timeout: 3) { model.audioPermission == .granted }
        XCTAssertEqual(model.audioPermission, .granted)
    }

    /// The real permission problem, and the banner's whole reason to exist: Party Mode
    /// on, and not one audible frame since.
    func testASessionThatNeverHearsAudioRaisesTheBanner() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        environment.source.setPermissionOnStart(.unknown)
        await startParty(environment)

        await goQuiet(environment)
        XCTAssertFalse(environment.model.hasHeardAudioThisSession)
        XCTAssertEqual(environment.model.banner, .audioDenied)
        XCTAssertEqual(environment.model.statusLine, "1 bulb. No audio is reaching Glowbeat.")
    }

    /// A song ending. Before this, it said "allow the permission" in red.
    func testSilenceAfterMusicWaitsForMusicWithoutABanner() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let model = environment.model
        await startParty(environment)
        await waitForMusic(model)
        XCTAssertTrue(model.hasHeardAudioThisSession)

        await goQuiet(environment)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.statusLine, "1 bulb. Waiting for music.")

        // The next track.
        environment.source.emitPermission(.granted)
        await waitForMusic(model)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.statusLine, "1 bulb. Listening to system audio.")
    }

    /// Switching Party Mode off ends the session, so the next one has to hear music for
    /// itself before silence stops counting as trouble.
    func testANewSessionForgetsThatTheLastOneHeardMusic() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let model = environment.model
        await startParty(environment)
        await waitForMusic(model)
        await goQuiet(environment)
        XCTAssertNil(model.banner, "The first session heard music, so its silence is a pause.")

        model.setPartyModeEnabled(false)
        let stopped = await waitForParty(model) { $0 == .off }
        XCTAssertEqual(stopped, .off)
        XCTAssertFalse(model.hasHeardAudioThisSession, "Stopping ends the session.")

        // A tap that opens and hears nothing, the way the real one reports it.
        environment.source.setPermissionOnStart(.unknown)
        model.setPartyModeEnabled(true)
        let restarted = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(restarted, .running)
        await waitFor(timeout: 3) { model.audioPermission == .unknown }
        XCTAssertEqual(model.audioPermission, .unknown)

        await goQuiet(environment)
        XCTAssertFalse(model.hasHeardAudioThisSession)
        XCTAssertEqual(model.banner, .audioDenied)
        XCTAssertEqual(model.statusLine, "1 bulb. No audio is reaching Glowbeat.")
    }

    /// The other half of the reset: a new session that does hear music is as calm about a
    /// pause as the first one was, even when the music arrives before Party Mode has
    /// finished switching on.
    ///
    /// That window is real. `SystemAudioTap` hears its first audible frame on its own IO
    /// queue, possibly before the engine is back on the main actor to call itself
    /// running, and it only reports again on a change, so music missed there stays
    /// missed until the next gap. The second session is used because only then is the
    /// engine's permission reader already listening while the tap is still opening.
    func testMusicHeardWhilePartyModeIsStillSwitchingOnCounts() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let model = environment.model
        await startParty(environment)
        await waitForMusic(model)
        await goQuiet(environment)
        model.setPartyModeEnabled(false)
        let stopped = await waitForParty(model) { $0 == .off }
        XCTAssertEqual(stopped, .off)

        // A tap that takes half a second to open and then reports nothing, the way the
        // real one does, and music that is already playing while it opens.
        environment.source.setStartDelay(0.5)
        environment.source.setPermissionOnStart(.unknown)
        model.setPartyModeEnabled(true)
        XCTAssertTrue(model.isPartyTransitioning)
        environment.source.emitPermission(.granted)
        await waitForMusic(model)
        XCTAssertEqual(model.partyState, .off, "The music has to land before the start finishes.")
        XCTAssertTrue(model.isPartyTransitioning)

        let restarted = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(restarted, .running)
        XCTAssertTrue(model.hasHeardAudioThisSession)

        await goQuiet(environment)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.statusLine, "1 bulb. Waiting for music.")
    }

    /// A tap that will not open is the permission problem too, whatever an earlier
    /// session heard.
    func testATapThatWillNotOpenStillRaisesTheBanner() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let model = environment.model
        await startParty(environment)
        await waitForMusic(model)
        model.setPartyModeEnabled(false)
        let stopped = await waitForParty(model) { $0 == .off }
        XCTAssertEqual(stopped, .off)

        environment.source.setStartError(CocoaError(.featureUnsupported))
        model.setPartyModeEnabled(true)
        await waitFor(timeout: 3) { model.audioStartFailed }
        XCTAssertTrue(model.audioStartFailed)
        XCTAssertEqual(model.partyState, .off)
        XCTAssertEqual(model.banner, .audioDenied)
        XCTAssertEqual(model.statusLine, "1 bulb. Glowbeat could not listen to system audio.")
    }

    /// A phone takeover pauses the session and Resume carries on with it, so what it
    /// already heard still counts.
    func testPausingAndResumingKeepsWhatTheSessionHeard() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let model = environment.model
        await startParty(environment)
        await waitForMusic(model)

        // The session's baseline is its first status report, so give it one before the
        // phone moves anything. Party Mode polls every second.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var changed = fakeBulbs[0].currentState()
        changed.brightness = 12
        fakeBulbs[0].applyExternalChange(changed)
        let paused = await waitForParty(model) {
            if case .paused = $0 { return true }
            return false
        }
        guard case .paused = paused else {
            return XCTFail("Party Mode did not pause. State is \(paused).")
        }
        XCTAssertTrue(model.hasHeardAudioThisSession)

        model.resumeParty()
        let resumed = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(resumed, .running)
        XCTAssertTrue(model.hasHeardAudioThisSession)

        await goQuiet(environment)
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.statusLine, "1 bulb. Waiting for music.")
    }

    // MARK: Status polls share the room's budget too

    /// Party Mode polls every bulb once a second, which in a room of six is six requests
    /// and six replies a second on top of the colors. Past six bulbs the room keeps to
    /// that: the interval stretches so the whole room is asked six times a second.
    func testThePartyPollIntervalKeepsTheRoomAtSixPollsASecond() {
        XCTAssertEqual(AppModel.partyPollInterval(forBulbCount: 0), 1)
        XCTAssertEqual(AppModel.partyPollInterval(forBulbCount: 1), 1)
        XCTAssertEqual(AppModel.partyPollInterval(forBulbCount: 6), 1)
        XCTAssertEqual(AppModel.partyPollInterval(forBulbCount: 10), 10.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(AppModel.partyPollInterval(forBulbCount: 15), 2.5, accuracy: 0.0001)
    }

    func testPartyModePollsAtTheRoomsIntervalAndGoesBackToIdleAfter() async throws {
        let environment = try makeModel(bulbCount: 7)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 7)
        XCTAssertEqual(model.bulbs.count, 7)

        model.setPartyModeEnabled(true)
        let started = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(started, .running)
        var interval = await model.statusPollInterval()
        let deadline = Date().addingTimeInterval(3)
        while abs(interval - 7.0 / 6) > 0.0001, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            interval = await model.statusPollInterval()
        }
        XCTAssertEqual(interval, 7.0 / 6, accuracy: 0.0001)

        model.setPartyModeEnabled(false)
        let idleDeadline = Date().addingTimeInterval(3)
        while interval != 10, Date() < idleDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            interval = await model.statusPollInterval()
        }
        XCTAssertEqual(interval, 10)
    }

    // MARK: Party Mode baselines and the color window

    func testStartingPartyModeRightAfterAGlowbeatCommandDoesNotFalsePause() async throws {
        // A slow idle poll leaves the last reported state stale by the time Party Mode
        // starts, which is exactly the window a false pause used to live in.
        let environment = try makeModel(bulbCount: 1, pollInterval: 5)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        let model = environment.model
        await waitFor(timeout: 5) { model.bulbs.first?.state != nil }
        XCTAssertEqual(environment.model.bulbs.first?.state?.brightness, 100)

        // Glowbeat dims the bulb. The next idle poll is five seconds away, so the
        // model's reported state still says 100.
        environment.model.setBrightness(40, for: nil)
        let bulb = fakeBulbs[0]
        await waitFor(timeout: 3) { bulb.currentState().brightness == 40 }
        XCTAssertEqual(bulb.currentState().brightness, 40)
        XCTAssertEqual(environment.model.bulbs.first?.state?.brightness, 100)

        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)

        // Two party polls at one second each, both reporting 40 against a baseline that
        // must have come from the command rather than from the stale report.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(environment.model.partyState, .running)
    }

    /// The baseline is lazy: it is whatever the first status report of the session says,
    /// not what Glowbeat last sent. A phone change made while Party Mode was off is
    /// already the truth by the time Party Mode starts, so it must not pause the session
    /// it never interrupted.
    func testAPhoneChangeMadeWhilePartyModeWasOffDoesNotPauseTheNewSession() async throws {
        let environment = try makeModel(bulbCount: 1, pollInterval: 0.3)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        // Glowbeat dims the bulb, so the controller has a one shot on record.
        environment.model.setBrightness(90, for: nil)
        let bulb = fakeBulbs[0]
        await waitFor(timeout: 3) { bulb.currentState().brightness == 90 }
        XCTAssertEqual(bulb.currentState().brightness, 90)

        // Party Mode is still off. Someone picks up the phone and dims it further.
        var changed = bulb.currentState()
        changed.brightness = 20
        bulb.applyExternalChange(changed)

        let model = environment.model
        await waitFor(timeout: 5) { model.bulbs.first?.state?.brightness == 20 }
        XCTAssertEqual(environment.model.bulbs.first?.state?.brightness, 20)

        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)

        // Two party polls at one second each, both reporting the phone's brightness.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(environment.model.partyState, .running)
    }

    func testStreamedPartyColorsAreNotMistakenForAPhone() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)

        let bulb = fakeBulbs[0]
        let sent = await streamColors(environment, to: bulb)
        XCTAssertFalse(sent.isEmpty)

        // Three party polls, every one reporting a color Glowbeat itself streamed.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(environment.model.partyState, .running)
    }

    func testAnExternalColorChangePausesOnlyAfterAThirdPoll() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        environment.model.setPartyModeEnabled(true)
        let started = await waitForParty(environment.model) { $0 == .running }
        XCTAssertEqual(started, .running)

        let bulb = fakeBulbs[0]
        let sent = await streamColors(environment, to: bulb)
        XCTAssertFalse(sent.isEmpty)

        // A color no Party Mode tick could have produced, and no fade between two ticks
        // could pass through.
        let candidates = [GoveeRGB(r: 0, g: 255, b: 0),
                          GoveeRGB(r: 255, g: 0, b: 255),
                          GoveeRGB(r: 255, g: 255, b: 255)]
        let far = try XCTUnwrap(candidates.first { candidate in
            !ExternalChangeDetector.isExplained(candidate, bySent: sent)
        })
        var changed = bulb.currentState()
        changed.color = far
        let changedAt = Date()
        bulb.applyExternalChange(changed)

        let paused = await waitForParty(environment.model, timeout: 8) {
            if case .paused = $0 { return true }
            return false
        }
        let elapsed = Date().timeIntervalSince(changedAt)
        guard case .paused(let reason) = paused else {
            return XCTFail("Party Mode did not pause. State is \(paused).")
        }
        XCTAssertTrue(reason.contains("color was changed"))
        // Neither one poll nor two is enough. The third poll for a bulb cannot arrive
        // sooner than two full intervals after the first, so a pause inside that would
        // mean fewer than three unexplained colors had been trusted.
        XCTAssertGreaterThan(elapsed, 1.9)
    }

    // MARK: False takeovers (Phil, 2026-09-23)
    //
    // "It says a color was changed from the Govee app but nothing. I didn't do anything.
    // That's happened multiple times lately since I added more light bulbs." These put
    // exact colors on the wire through the model's own controller, a tenth of a second
    // apart the way Party Mode streams them, then make the fake bulb report what a real
    // H6004 can report on a busy network, and count the polls it answers.

    /// Party Mode running on the one fake bulb, with the session's first report (its
    /// baseline) already taken, so every poll from here on is judged. Returns the model's
    /// bulb, which is what the controller sends to.
    private func startPartyAndTakeBaseline(_ environment: Environment) async throws -> Bulb {
        await startParty(environment)
        await waitForPolls(1, of: fakeBulbs[0])
        return try XCTUnwrap(environment.model.bulbs.first)
    }

    /// Waits until the fake bulb has answered `count` more status polls, then gives the
    /// last reply time to cross the loopback socket and be judged by the model.
    private func waitForPolls(_ count: Int, of bulb: FakeBulb) async {
        let target = statusPolls(bulb) + count
        await waitFor(timeout: Double(count) * 1.5 + 2) { statusPolls(bulb) >= target }
        XCTAssertGreaterThanOrEqual(statusPolls(bulb), target,
                                    "The fake bulb was not polled \(count) more times.")
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Sends `colors` through the controller exactly as Party Mode's ticks would, one
    /// every tenth of a second on the rate limiter's clock, and waits until the fake bulb
    /// has every one of them.
    private func stream(_ colors: [GoveeRGB],
                        to bulb: Bulb,
                        via environment: Environment) async {
        let fake = fakeBulbs[0]
        let start = Date()
        for (index, color) in colors.enumerated() {
            await environment.controller.streamColor(color,
                                                     to: bulb,
                                                     at: start.addingTimeInterval(Double(index) * 0.1))
        }
        await waitFor(timeout: 3) { Array(recordedColors(fake).suffix(colors.count)) == colors }
        XCTAssertEqual(Array(recordedColors(fake).suffix(colors.count)), colors,
                       "The rate limiter held back a color the test meant to send.")
    }

    /// What the bulb will say in its next status replies.
    private func bulbReports(_ color: GoveeRGB, on fake: FakeBulb) {
        var state = fake.currentState()
        state.color = color
        fake.applyExternalChange(state)
    }

    /// Five reds, the last half second of a session. Their fade paths all run along the
    /// red axis, so nothing with any green or blue in it is explained by them.
    private let fiveReds = (0..<5).map { (step: Int) -> GoveeRGB in
        GoveeRGB(r: UInt8(120 + step * 30), g: 0, b: 0)
    }

    /// A bulb that is behind (a dropped or queued datagram, a reply that comes back late)
    /// reports a color Glowbeat did send, just not one of the last five. At ten sends a
    /// second five colors is half a second of Party Mode, so two such polls in a row used
    /// to pause the session.
    func testABulbStillShowingAColorFromTenSendsAgoDoesNotPause() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let bulb = try await startPartyAndTakeBaseline(environment)
        let fake = fakeBulbs[0]

        // A second and a half of Party Mode: ten blues and greens, then the five reds.
        let earlier = (0..<10).map { (step: Int) -> GoveeRGB in
            GoveeRGB(r: 0, g: UInt8(step * 20), b: UInt8(250 - step * 20))
        }
        let colors = earlier + fiveReds
        await stream(colors, to: bulb, via: environment)

        // The bulb is stuck ten sends back, and stays there for two polls.
        let lagged = colors[colors.count - 11]
        bulbReports(lagged, on: fake)
        await waitForPolls(2, of: fake)

        XCTAssertEqual(environment.model.partyState, .running,
                       "A color Glowbeat sent a second ago was read as the Govee app.")
    }

    /// The H6004 fades between `colorwc` colors, so a poll can land part way along the
    /// fade from one sent color to the next and report a color that is neither.
    func testABulbCaughtMidFadeBetweenTwoSentColorsDoesNotPause() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let bulb = try await startPartyAndTakeBaseline(environment)
        let fake = fakeBulbs[0]

        let from = GoveeRGB(r: 220, g: 20, b: 0)
        let to = GoveeRGB(r: 20, g: 60, b: 200)
        await stream([from, to], to: bulb, via: environment)

        // Three tenths of the way from one to the other (160, 32, 60), a few steps off
        // the line the way a rounding firmware would be, and at least 57 away from both
        // ends on some channel.
        bulbReports(GoveeRGB(r: 163, g: 29, b: 60), on: fake)
        await waitForPolls(2, of: fake)

        XCTAssertEqual(environment.model.partyState, .running,
                       "A color on the fade between two sent colors was read as the Govee app.")
    }

    /// A bulb that is behind or mid fade reports a different wrong color on every poll.
    /// A phone sets one color and leaves it. Only the second is a takeover.
    func testAnUnexplainedColorThatWandersFromPollToPollDoesNotPause() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let bulb = try await startPartyAndTakeBaseline(environment)
        let fake = fakeBulbs[0]
        await stream(fiveReds, to: bulb, via: environment)

        // Every one of these is far from every red and at least 60 from each other.
        let wandering = [GoveeRGB(r: 0, g: 200, b: 60),
                         GoveeRGB(r: 0, g: 90, b: 220),
                         GoveeRGB(r: 30, g: 240, b: 240),
                         GoveeRGB(r: 0, g: 140, b: 120)]
        for color in wandering {
            bulbReports(color, on: fake)
            await waitForPolls(1, of: fake)
        }

        XCTAssertEqual(environment.model.partyState, .running,
                       "Four different unexplained colors in a row were read as the Govee app.")
    }

    /// The true positive the whole check exists for: someone picks a color in Govee Home
    /// and it stays. Two polls are not enough to say so. The third is.
    func testASteadyColorGlowbeatNeverSentPausesOnTheThirdPoll() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let bulb = try await startPartyAndTakeBaseline(environment)
        let fake = fakeBulbs[0]
        await stream(fiveReds, to: bulb, via: environment)

        bulbReports(GoveeRGB(r: 0, g: 200, b: 60), on: fake)
        await waitForPolls(2, of: fake)
        XCTAssertEqual(environment.model.partyState, .running,
                       "Two polls are not enough to call a phone.")

        await waitForPolls(1, of: fake)
        guard case .paused(let reason) = environment.model.partyState else {
            return XCTFail("A steady phone color did not pause Party Mode on the third poll. "
                           + "State is \(environment.model.partyState).")
        }
        XCTAssertEqual(reason, ExternalChangeDetector.Finding.color.reason)
    }

    /// Quiet music sends nothing, so the send history can go longer than its three second
    /// window without a new color. The bulb is still holding the last one, and a phone
    /// color in that quiet is still a phone.
    func testAPhoneColorWellAfterTheLastSendStillPauses() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let bulb = try await startPartyAndTakeBaseline(environment)
        let fake = fakeBulbs[0]
        await stream(fiveReds, to: bulb, via: environment)
        let lastSend = Date()

        // Four quiet polls, the last well past the window, all reporting the last red.
        await waitForPolls(4, of: fake)
        XCTAssertGreaterThan(Date().timeIntervalSince(lastSend), 3.2)
        XCTAssertEqual(environment.model.partyState, .running)

        bulbReports(GoveeRGB(r: 0, g: 200, b: 60), on: fake)
        await waitForPolls(3, of: fake)
        guard case .paused(let reason) = environment.model.partyState else {
            return XCTFail("A phone color after a quiet stretch did not pause Party Mode. "
                           + "State is \(environment.model.partyState).")
        }
        XCTAssertEqual(reason, ExternalChangeDetector.Finding.color.reason)
    }

    /// Unchanged by the color rules: a phone switching a bulb off pauses on the first
    /// poll that says so.
    func testAPhoneSwitchingABulbOffStillPausesOnTheFirstPoll() async throws {
        let environment = try makeModel(bulbCount: 1)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)
        let fake = fakeBulbs[0]
        environment.model.setPower(true, for: environment.model.bulbs[0])
        await waitFor(timeout: 3) { fake.currentState().isOn }
        XCTAssertTrue(fake.currentState().isOn)

        let bulb = try await startPartyAndTakeBaseline(environment)
        await stream(fiveReds, to: bulb, via: environment)

        var off = fake.currentState()
        off.isOn = false
        fake.applyExternalChange(off)
        await waitForPolls(1, of: fake)

        guard case .paused(let reason) = environment.model.partyState else {
            return XCTFail("Switching a bulb off from the phone did not pause Party Mode. "
                           + "State is \(environment.model.partyState).")
        }
        XCTAssertEqual(reason, ExternalChangeDetector.Finding.power.reason)
    }

    // MARK: Party Mode's own full brightness (2026-09-23)
    //
    // "The bulbs rarely reach actual 100% very much." Party Mode now sets every bulb's own
    // brightness to 100 when it starts, so its Darkest and Brightest mean what they say.
    // That is a brightness Glowbeat sent, which the takeover check judges every poll
    // against, and a UDP command can take a repeat or two to land.

    /// Party Mode sets the brightness once, at the start, and never again while it
    /// streams. A bulb that took it is judged against it and passes.
    func testPartyModeSetsFullBrightnessOnceAndItsOwnCommandNeverPauses() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let fake = fakeBulbs[0]
        var dimmed = fake.currentState()
        dimmed.brightness = 30
        fake.applyExternalChange(dimmed)
        _ = try await startPartyAndTakeBaseline(environment)
        await waitFor(timeout: 3) { fake.currentState().brightness == 100 }
        XCTAssertEqual(fake.currentState().brightness, 100)
        fake.clearRecordedCommands()

        let sent = await streamColors(environment, to: fake)
        XCTAssertFalse(sent.isEmpty)
        await waitForPolls(3, of: fake)

        let brightnessCommands = fake.recordedCommands().filter {
            if case .brightness = $0 { return true }
            return false
        }
        XCTAssertEqual(brightnessCommands, [], "Party Mode sent a brightness while streaming.")
        XCTAssertEqual(environment.model.partyState, .running)
    }

    /// The bulb heard the 100 and is still at 30 for a poll or two (a dropped datagram,
    /// the repeat a second behind). That is Glowbeat's own command in flight, not a phone.
    func testABulbStillOnItsOldBrightnessAfterPartyModeSetsItDoesNotPause() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let fake = fakeBulbs[0]
        var dimmed = fake.currentState()
        dimmed.brightness = 30
        fake.applyExternalChange(dimmed)
        fake.setAppliesBrightness(false)

        _ = try await startPartyAndTakeBaseline(environment)
        await waitFor(timeout: 3) { fake.recordedCommands().contains(.brightness(100)) }
        XCTAssertTrue(fake.recordedCommands().contains(.brightness(100)))
        await waitForPolls(2, of: fake)
        XCTAssertEqual(fake.currentState().brightness, 30)
        XCTAssertEqual(environment.model.partyState, .running,
                       "Party Mode's own brightness, not landed yet, was read as the Govee app.")

        // The repeat lands.
        fake.setAppliesBrightness(true)
        var caughtUp = fake.currentState()
        caughtUp.brightness = 100
        fake.applyExternalChange(caughtUp)
        await waitForPolls(2, of: fake)
        XCTAssertEqual(environment.model.partyState, .running)
    }

    /// The true positive is untouched: once the bulb has shown the 100, a phone dimming it
    /// pauses on the first poll that says so.
    func testAPhoneBrightnessAfterTheBulbShowedFullBrightnessStillPauses() async throws {
        let environment = try makeModel(bulbCount: 1)
        defer { environment.model.stopServices() }
        let fake = fakeBulbs[0]
        var dimmed = fake.currentState()
        dimmed.brightness = 30
        fake.applyExternalChange(dimmed)

        _ = try await startPartyAndTakeBaseline(environment)
        await waitFor(timeout: 3) { fake.currentState().brightness == 100 }
        XCTAssertEqual(fake.currentState().brightness, 100)
        // One poll that reports the 100.
        await waitForPolls(1, of: fake)
        XCTAssertEqual(environment.model.partyState, .running)

        var phone = fake.currentState()
        phone.brightness = 40
        fake.applyExternalChange(phone)
        await waitForPolls(1, of: fake)

        guard case .paused(let reason) = environment.model.partyState else {
            return XCTFail("A phone brightness after the bulb showed 100 did not pause. "
                           + "State is \(environment.model.partyState).")
        }
        XCTAssertEqual(reason, ExternalChangeDetector.Finding.brightness.reason)
    }


    // MARK: Network recovery

    /// Waking the Mac or changing networks leaves the socket bound to an interface that
    /// may be gone. Rebuilding it has to bring discovery and polling back with it, not
    /// just the socket, or the app looks alive and hears nothing.
    func testRestartingTheNetworkFindsTheBulbsAgain() async throws {
        let environment = try makeModel(bulbCount: 2)
        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)
        XCTAssertEqual(environment.model.bulbs.count, 2)

        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        environment.model.restartNetwork()

        // A scan reaching both bulbs proves the send path came back.
        let bulbs = fakeBulbs
        await waitFor(timeout: 8) {
            bulbs.allSatisfy { $0.recordedCommands().contains(.scan) }
        }
        XCTAssertTrue(fakeBulbs.allSatisfy { $0.recordedCommands().contains(.scan) },
                      "Discovery never scanned again after the socket was rebuilt.")

        // A state change only the poller could have seen proves the receive path did too.
        var changed = fakeBulbs[0].currentState()
        changed.brightness = 33
        fakeBulbs[0].applyExternalChange(changed)

        let model = environment.model
        // By device id, not by position: the list is in the user's own bulb order.
        let id = "AA:00"
        await waitFor(timeout: 8) {
            model.bulbs.first(where: { $0.id == id })?.state?.brightness == 33
        }
        XCTAssertEqual(model.bulbs.first(where: { $0.id == id })?.state?.brightness, 33,
                      "Status polling never resumed after the socket was rebuilt.")
        XCTAssertFalse(environment.model.networkUnavailable)
        XCTAssertTrue(environment.model.bulbs.allSatisfy(\.isReachable))
    }

    /// A socket that will not open is the whole app, so it says so. Blaming LAN Control
    /// in Govee Home for a Wi-Fi problem sends the user to the wrong place entirely.
    func testASocketThatCannotOpenReportsThatTheNetworkIsUnavailable() throws {
        let blocker = try XCTUnwrap(BlockedPort(), "Could not bind a port to block.")
        defer { blocker.close() }

        let environment = try makeModel(bulbCount: 0,
                                        replyPort: blocker.port,
                                        startsSocket: false)
        environment.model.startServices()
        defer { environment.model.stopServices() }

        XCTAssertTrue(environment.model.networkUnavailable)
        XCTAssertTrue(environment.model.statusLine.contains("Network unavailable: check Wi-Fi"),
                      "The status line said \(environment.model.statusLine).")
        XCTAssertEqual(environment.model.banner, .networkUnavailable)
    }

    // MARK: Service lifecycle

    func testServicesCanBeStoppedAndStartedAgain() async throws {
        let environment = try makeModel(bulbCount: 2)
        // The second bulb has LAN Control off to begin with, so a restart has something
        // new to find. Stopping must not tear the reader loops down for good.
        fakeBulbs[1].setAnswersScan(false)
        environment.model.startServices()
        await waitForBulbs(environment.model, count: 1)
        XCTAssertEqual(environment.model.bulbs.count, 1)

        environment.model.stopServices()
        fakeBulbs[1].setAnswersScan(true)

        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 2)
        XCTAssertEqual(environment.model.bulbs.count, 2)
    }

    // MARK: Party Mode helpers

    /// Feeds the engine real frames and fires the manual tick source, so Party Mode
    /// actually streams colors to the fake bulb. Returns everything the bulb received.
    private func streamColors(_ environment: Environment,
                              to bulb: FakeBulb) async -> [GoveeRGB] {
        environment.source.emitMetronome(frameCount: 60)
        // The engine reads frames on its own task, so let those land before ticking.
        try? await Task.sleep(nanoseconds: 200_000_000)
        environment.ticks.fire(3)
        await waitFor(timeout: 3) { !recordedColors(bulb).isEmpty }
        return recordedColors(bulb)
    }

    /// Runs one Wave beat and returns the id of the bulb that got the head of it.
    ///
    /// Wave pushes the new palette color into the first bulb at full level and shifts
    /// every older color one bulb along, fading it. The head is therefore the brightest
    /// color anybody receives on the tick, by a wide margin, and which bulb receives it
    /// is exactly the question "who does the engine think is first". A beat does not
    /// land on every tick, so this retries until one clearly does.
    private func waveHeadBulbID(_ environment: Environment) async -> String? {
        func luma(_ color: GoveeRGB) -> Int {
            Int(color.r) + Int(color.g) + Int(color.b)
        }
        for _ in 0..<12 {
            for fake in fakeBulbs { fake.clearRecordedCommands() }
            // The frame clock has to keep moving across rounds and across both halves of
            // a test. Restarting it at zero makes the engine see time going backwards,
            // and the beat detector stops finding edges in audio it has already heard.
            environment.source.emitMetronome(frameCount: 60, startTime: streamTime)
            streamTime += 2
            // The engine reads frames on its own task, so let those land before ticking.
            try? await Task.sleep(nanoseconds: 150_000_000)
            environment.ticks.fire(1)
            try? await Task.sleep(nanoseconds: 250_000_000)

            let brightest = fakeBulbs.enumerated().map { index, fake in
                (id: "AA:0\(index)", luma: recordedColors(fake).map(luma).max() ?? 0)
            }.sorted { $0.luma > $1.luma }
            let runnerUp = brightest.dropFirst().first?.luma ?? 0
            // A palette color at full level, not a cell that is already fading, and a
            // clear winner rather than a bulb a shade ahead of its neighbor.
            guard let head = brightest.first, head.luma > 150, head.luma > runnerUp * 2 else {
                continue
            }
            return head.id
        }
        return nil
    }

    // MARK: Bulb order

    func testMovingABulbReordersTheListAndPersistsTheNewOrder() async throws {
        let environment = try makeModel(bulbCount: 3)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        // Bulbs nobody has arranged yet land in the order they answered the scan, which
        // is whatever the network decided, so the move is measured against that rather
        // than against an order this test made up.
        let initial = model.orderedBulbs.map(\.id)
        XCTAssertEqual(Set(initial), ["AA:00", "AA:01", "AA:02"])

        model.moveBulbs(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let moved = [initial[2], initial[0], initial[1]]

        XCTAssertEqual(model.orderedBulbs.map(\.id), moved)
        // The published list is what the rows read, so it moves with the stored order
        // rather than waiting for the next discovery snapshot to sort it.
        XCTAssertEqual(model.bulbs.map(\.id), moved)
        XCTAssertEqual(try sharedDefaults().stringArray(forKey: "bulbOrder"), moved)
        // The numbered fallback name follows the position, not the bulb.
        XCTAssertEqual(model.displayName(for: model.bulbs[0]), "Bulb 1")
    }

    // MARK: Spread band assignment

    /// With nothing chosen every bulb takes the round robin, which is Spread's old
    /// behavior: the fallback follows the position in the list, so a reorder changes it.
    func testAnUnassignedBulbTakesTheRoundRobinForItsPosition() async throws {
        let environment = try makeModel(bulbCount: 3)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        let initial = model.orderedBulbs.map(\.id)
        XCTAssertEqual(initial.map { model.spreadGroup(for: $0) }, [.bass, .mid, .high])

        model.moveBulbs(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.spreadGroup(for: initial[2]), .bass,
                       "The fallback follows the position, so moving a bulb moves its band.")
        XCTAssertEqual(model.spreadGroup(for: initial[0]), .mid)
        XCTAssertEqual(model.spreadGroup(for: initial[1]), .high)
    }

    /// A chosen band belongs to the bulb, not to the slot, so it survives a reorder and
    /// a relaunch.
    func testAChosenBandSticksToTheBulbThroughAReorderAndARelaunch() async throws {
        let environment = try makeModel(bulbCount: 3)
        let model = environment.model
        model.startServices()
        await waitForBulbs(model, count: 3)
        let initial = model.orderedBulbs.map(\.id)

        model.setSpreadGroup(.high, for: initial[0])
        XCTAssertEqual(model.spreadGroup(for: initial[0]), .high)
        XCTAssertEqual(model.settings.spreadAssignments[initial[0]], SpreadGroup.high.rawValue)
        // The bulbs nobody chose for keep falling back by position.
        XCTAssertEqual(model.spreadGroup(for: initial[1]), .mid)

        model.moveBulbs(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.spreadGroup(for: initial[0]), .high,
                       "A chosen band belongs to the bulb, not to the slot.")
        model.stopServices()

        let relaunched = try relaunch()
        relaunched.model.startServices()
        defer { relaunched.model.stopServices() }
        await waitForBulbs(relaunched.model, count: 3)
        XCTAssertEqual(relaunched.model.spreadGroup(for: initial[0]), .high)
    }

    /// Choosing a band while Spread is running has to reach the room on the next tick,
    /// which is only visible through the engine's copy of the assignment.
    func testChoosingABandReachesTheRunningSpread() async throws {
        let environment = try makeModel(bulbCount: 3)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        let ordered = model.orderedBulbs.map(\.id)

        model.setEffect(.spread)
        model.setPartyModeEnabled(true)
        let state = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(state, .running)

        XCTAssertEqual(model.partyEngineSpreadAssignment, [.bass, .mid, .high],
                       "A start hands the effect the room's current assignment.")
        model.setSpreadGroup(.bass, for: ordered[2])
        XCTAssertEqual(model.partyEngineSpreadAssignment, [.bass, .mid, .bass],
                       "Choosing a band must reach the running effect, live.")

        model.setPartyModeEnabled(false)
        _ = await waitForParty(model) { $0 == .off }
    }

    /// The Confetti switch: live while Party Mode runs, carried by a start, kept through a
    /// change of effect, and remembered across a relaunch.
    func testConfettiIsLiveAndRemembered() async throws {
        let environment = try makeModel(bulbCount: 2)
        let model = environment.model
        model.startServices()
        await waitForBulbs(model, count: 2)
        XCTAssertFalse(model.settings.partyConfetti, "Confetti ships off.")

        model.setPartyConfetti(true)
        XCTAssertTrue(model.settings.partyConfetti)
        XCTAssertTrue(try sharedDefaults().bool(forKey: "partyConfetti"), "Saved at once.")

        model.setPartyModeEnabled(true)
        let state = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(state, .running)
        XCTAssertEqual(model.partyEngineConfetti, true, "A start hands the effect confetti.")

        model.setPartyConfetti(false)
        XCTAssertEqual(model.partyEngineConfetti, false, "The switch is live.")
        model.setPartyConfetti(true)
        model.setEffect(.wave)
        XCTAssertEqual(model.partyEngineConfetti, true, "A new effect keeps confetti.")

        model.setPartyModeEnabled(false)
        _ = await waitForParty(model) { $0 == .off }
        model.stopServices()

        let relaunched = try relaunch()
        XCTAssertTrue(relaunched.model.settings.partyConfetti, "Remembered across a relaunch.")
    }

    func testTheStoredOrderSurvivesARelaunch() async throws {
        let environment = try makeModel(bulbCount: 3)
        environment.model.startServices()
        await waitForBulbs(environment.model, count: 3)
        let initial = environment.model.orderedBulbs.map(\.id)
        environment.model.moveBulbs(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let moved = [initial[1], initial[2], initial[0]]
        XCTAssertEqual(environment.model.orderedBulbs.map(\.id), moved)
        environment.model.stopServices()

        let relaunched = try relaunch()
        relaunched.model.startServices()
        defer { relaunched.model.stopServices() }
        await waitForBulbs(relaunched.model, count: 3)
        XCTAssertEqual(relaunched.model.orderedBulbs.map(\.id), moved)
        XCTAssertEqual(relaunched.model.bulbs.map(\.id), moved)
    }

    /// A bulb the order has never heard of goes to the end of it and stays there, so
    /// buying a fourth bulb does not shuffle the three that are already arranged.
    func testABulbMissingFromTheStoredOrderIsAppendedToIt() async throws {
        let environment = try makeModel(bulbCount: 3)
        let store = BulbNameStore(defaults: try sharedDefaults())
        store.setOrder(["AA:02"])

        environment.model.startServices()
        defer { environment.model.stopServices() }
        await waitForBulbs(environment.model, count: 3)

        // The one arranged bulb keeps the top; the two the order had never seen are
        // appended behind it in whatever order they answered.
        XCTAssertEqual(environment.model.orderedBulbs.first?.id, "AA:02")
        XCTAssertEqual(Set(environment.model.orderedBulbs.dropFirst().map(\.id)),
                       ["AA:00", "AA:01"])
        XCTAssertEqual(store.order(), environment.model.orderedBulbs.map(\.id))
    }

    /// The list only ever holds the bulbs that answered a scan. Dragging one of them
    /// must not forget where an unplugged bulb belonged.
    func testAMoveKeepsTheStoredPlaceOfABulbThatIsNotOnTheListRightNow() async throws {
        let environment = try makeModel(bulbCount: 2)
        let store = BulbNameStore(defaults: try sharedDefaults())
        // "ZZ:99" is arranged between the two, and is switched off at the wall today.
        store.setOrder(["AA:00", "ZZ:99", "AA:01"])

        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.orderedBulbs.map(\.id), ["AA:00", "AA:01"])

        model.moveBulbs(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(model.orderedBulbs.map(\.id), ["AA:01", "AA:00"])
        XCTAssertEqual(store.order(), ["AA:01", "ZZ:99", "AA:00"],
                       "A bulb that was not on screen lost its place in the order.")
    }

    /// The order is what Wave travels along, so a reorder made mid session has to reach
    /// the engine, not just the list.
    func testAMoveDuringAPartySessionChangesWhereTheWaveStarts() async throws {
        let environment = try makeModel(bulbCount: 3)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        model.setEffect(.wave)

        model.setPartyModeEnabled(true)
        let running = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(running, .running)

        let firstHead = await waveHeadBulbID(environment)
        XCTAssertEqual(firstHead, model.orderedBulbs.first?.id,
                       "The wave did not start at the top of the list.")

        // The bulb at the bottom of the list is dragged to the top.
        model.moveBulbs(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let newTop = try XCTUnwrap(model.orderedBulbs.first?.id)
        XCTAssertNotEqual(newTop, firstHead)

        let secondHead = await waveHeadBulbID(environment)
        XCTAssertEqual(secondHead, newTop,
                       "The running session kept sending the wave along the old order.")
    }

    // MARK: Identify

    func testIdentifyFlashesWhiteTwiceThenRestoresColorAndPower() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        // The real flash is spaced 350 ms apart. Nothing here is timing dependent, so
        // the test runs the same sequence without waiting a second and a half for it.
        model.setIdentifyStepInterval(0.02)
        let fake = fakeBulbs[0]
        let blue = GoveeRGB(r: 0, g: 40, b: 255)
        fake.applyExternalChange(BulbState(isOn: true,
                                           brightness: 70,
                                           color: blue,
                                           colorTemperatureKelvin: 0))
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        await waitFor(timeout: 5) { model.bulbs.first?.state?.color == blue }
        XCTAssertEqual(model.bulbs.first?.state?.isOn, true)

        fake.clearRecordedCommands()
        let bulb = model.bulbs[0]
        model.identify(bulb)
        XCTAssertTrue(model.isIdentifying(bulb))

        await waitFor(timeout: 5) { !model.isIdentifying(bulb) }
        XCTAssertFalse(model.isIdentifying(bulb))
        XCTAssertEqual(controlCommands(fake),
                       [.turn(true), .color(identifyWhite),
                        .turn(false), .turn(true), .turn(false),
                        .color(blue), .turn(true)])
        XCTAssertEqual(fake.currentState().color, blue)
        XCTAssertTrue(fake.currentState().isOn)
        // Identify never touches brightness, so "white at the current brightness" is
        // whatever the bulb was already at.
        XCTAssertEqual(fake.currentState().brightness, 70)
    }

    func testIdentifyRestoresABulbThatWasInWhiteMode() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.02)
        let fake = fakeBulbs[0]
        fake.applyExternalChange(BulbState(isOn: false,
                                           brightness: 40,
                                           color: GoveeRGB(r: 0, g: 0, b: 0),
                                           colorTemperatureKelvin: 3200))
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        await waitFor(timeout: 5) { model.bulbs.first?.state?.colorTemperatureKelvin == 3200 }
        XCTAssertEqual(model.bulbs.first?.state?.isOn, false)

        fake.clearRecordedCommands()
        let bulb = model.bulbs[0]
        model.identify(bulb)
        await waitFor(timeout: 5) { !model.isIdentifying(bulb) }

        XCTAssertEqual(controlCommands(fake),
                       [.turn(true), .color(identifyWhite),
                        .turn(false), .turn(true), .turn(false),
                        .colorTemperature(3200), .turn(false)])
        XCTAssertEqual(fake.currentState().colorTemperatureKelvin, 3200)
        // It was off before the flash, so it is off after it.
        XCTAssertFalse(fake.currentState().isOn)
    }

    /// Spec 4.4: with nothing ever reported for a bulb there is no previous state to go
    /// back to, so identify leaves it white rather than guessing one.
    func testIdentifyLeavesABulbWithNoReportedStateWhite() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.02)
        let fake = fakeBulbs[0]
        // Services are never started, so no status report ever reaches the model.
        let unreported = Bulb(id: "ZZ:99", sku: "H6004", endpoint: fake.endpoint())

        model.identify(unreported)
        await waitFor(timeout: 5) { !model.isIdentifying(unreported) }

        XCTAssertEqual(controlCommands(fake),
                       [.turn(true), .color(identifyWhite),
                        .turn(false), .turn(true), .turn(false), .turn(true)])
        XCTAssertEqual(fake.currentState().color, identifyWhite)
        XCTAssertTrue(fake.currentState().isOn)
    }

    func testASecondIdentifyOnTheSameBulbIsIgnoredWhileTheFirstIsRunning() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.05)
        let fake = fakeBulbs[0]
        let bulb = Bulb(id: "ZZ:99", sku: "H6004", endpoint: fake.endpoint())

        model.identify(bulb)
        model.identify(bulb)
        XCTAssertTrue(model.isIdentifying(bulb))
        await waitFor(timeout: 5) { !model.isIdentifying(bulb) }

        // One sequence, not two interleaved ones.
        XCTAssertEqual(controlCommands(fake).count, 6)
    }

    // MARK: The bulb list's height

    /// The bulb list lives inside the window's one scroller now, so it has to be exactly
    /// as tall as its rows. When it was greedy it took the whole window, scrolled inside
    /// itself, and left a patch of nothing between the last bulb and the Scenes header.
    func testTheBulbListIsExactlyAsTallAsItsRows() async throws {
        let environment = try makeModel(bulbCount: 6)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 6)
        XCTAssertEqual(model.bulbs.count, 6)

        // Offered far more room than it needs. A list that still scrolls inside itself
        // takes all of it.
        let renderer = ImageRenderer(content: BulbListView(model: model)
            .frame(width: 880)
            .frame(maxHeight: 2_000))
        let image = try XCTUnwrap(renderer.nsImage)
        let rows = BulbListMetrics.listHeight(forBulbCount: 6)
        XCTAssertEqual(rows, 6 * BulbListMetrics.rowHeight + 5, accuracy: 0.001)
        // The rows, plus the column header, the All bulbs row and their two rules. Well
        // under the room it was offered, and comfortably over the rows alone.
        XCTAssertGreaterThan(image.size.height, rows)
        XCTAssertLessThan(image.size.height, rows + 160,
                          "The bulb list is taking more room than its rows need.")
    }

    /// The height is the rows plus the rules between them, and it grows by exactly one row
    /// per bulb.
    func testTheListHeightIsOneRowPerBulb() {
        XCTAssertEqual(BulbListMetrics.listHeight(forBulbCount: 0), 0)
        XCTAssertEqual(BulbListMetrics.listHeight(forBulbCount: 1),
                       BulbListMetrics.rowHeight, accuracy: 0.001)
        for count in 1..<12 {
            let step = BulbListMetrics.listHeight(forBulbCount: count + 1)
                - BulbListMetrics.listHeight(forBulbCount: count)
            XCTAssertEqual(step, BulbListMetrics.rowHeight + 1, accuracy: 0.001,
                           "Bulb \(count + 1) has to add exactly one row.")
        }
    }

    // MARK: Scenes

    /// Scenes and Party Mode both stream colors at the same bulbs, so only one of them
    /// may ever be running.
    func testTurningASceneOnTurnsPartyModeOffAndTheOtherWayAround() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        XCTAssertEqual(model.bulbs.count, 1)

        model.setPartyModeEnabled(true)
        let running = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(running, .running)

        model.setScene(kind: .breathe)
        model.setSceneEnabled(true)
        XCTAssertEqual(model.sceneState, .running(.breathe))
        let stopped = await waitForParty(model) { $0 == .off }
        XCTAssertEqual(stopped, .off, "Starting a scene has to stop Party Mode.")

        model.setPartyModeEnabled(true)
        XCTAssertEqual(model.sceneState, .off, "Starting Party Mode has to stop the scene.")
        let restarted = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(restarted, .running)
        model.setPartyModeEnabled(false)
    }

    /// Spec section 4.4: launching never changes a bulb. A remembered scene is what the
    /// picker shows, not something that starts itself.
    func testASceneIsNeverRunningOnLaunch() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setScene(kind: .sunset)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)

        XCTAssertEqual(model.sceneState, .off)
        XCTAssertFalse(model.isSceneRunning)
        XCTAssertEqual(model.settings.sceneKind, .sunset)

        let relaunched = try relaunch()
        relaunched.model.startServices()
        defer { relaunched.model.stopServices() }
        XCTAssertEqual(relaunched.model.sceneState, .off)
        XCTAssertEqual(relaunched.model.settings.sceneKind, .sunset)
    }

    func testASceneReachesTheBulbsInTheUsersOrder() async throws {
        let environment = try makeModel(bulbCount: 2)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.bulbs.count, 2)

        model.setScene(kind: .fixed)
        model.setPalette(id: Palette.party.id)
        model.setSceneEnabled(true)
        environment.sceneTicks.fire()

        let ordered = model.orderedBulbs
        for (index, bulb) in ordered.enumerated() {
            // The fakes are built in id order, so the id says which one this is.
            guard let fakeIndex = (0..<fakeBulbs.count).first(where: { "AA:0\($0)" == bulb.id }) else {
                XCTFail("No fake bulb for \(bulb.id)")
                continue
            }
            let fake = fakeBulbs[fakeIndex]
            let expected = FrameBridge.goveeColor(from: Palette.party.colors[index])
            await waitFor(timeout: 3) { recordedColors(fake).contains(expected) }
            XCTAssertTrue(recordedColors(fake).contains(expected),
                          "Bulb \(index + 1) did not get the color its place in the list "
                              + "calls for.")
        }
        model.setSceneEnabled(false)
    }

    /// Single color mode: one palette color across the whole room, live.
    func testSingleColorModePutsOneColorOnEveryBulb() async throws {
        let environment = try makeModel(bulbCount: 2)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.bulbs.count, 2)

        model.setScene(kind: .fixed)
        model.setPalette(id: Palette.party.id)
        model.setSceneSingleColor(true)
        model.setSceneEnabled(true)

        let expected = FrameBridge.goveeColor(from: Palette.party.colors[0])
        for fake in fakeBulbs {
            let port = fake.port
            await tickScene(environment, until: { recordedColors(fake).contains(expected) })
            XCTAssertTrue(recordedColors(fake).contains(expected),
                          "Bulb \(port) did not get the single color.")
        }

        // And off again, live: the palette spreads back along the bulbs.
        for fake in fakeBulbs { fake.clearRecordedCommands() }
        model.setSceneSingleColor(false)
        // Which fake is second is a question for the stored order, not for the order the
        // fakes were built in: discovery replies arrive in whatever order the loopback
        // hands them over.
        let second = FrameBridge.goveeColor(from: Palette.party.colors[1])
        let secondBulb = model.orderedBulbs[1]
        let secondIndex = try XCTUnwrap((0..<fakeBulbs.count).first { "AA:0\($0)" == secondBulb.id })
        let spread = fakeBulbs[secondIndex]
        await tickScene(environment, until: { recordedColors(spread).contains(second) })
        XCTAssertTrue(recordedColors(spread).contains(second),
                      "Turning single color off has to spread the palette again.")
        model.setSceneEnabled(false)
    }

    /// Ticks a scene at the rate the engine really runs it until the predicate holds.
    ///
    /// Two ticks fired on top of each other are one send as far as the bulbs are
    /// concerned: the controller rate limits streamed colors, and the second is held until
    /// a later flush releases it. Spacing the ticks is what makes a scene test describe
    /// the running app rather than a burst nothing real produces.
    private func tickScene(_ environment: Environment,
                           timeout: TimeInterval = 3,
                           until predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        environment.sceneTicks.fire()
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 120_000_000)
            environment.sceneTicks.fire()
        }
    }

    /// The switch is remembered, and so is which of the window's sections are open.
    func testSingleColorAndTheOpenSectionsSurviveARelaunch() throws {
        let environment = try makeModel(bulbCount: 0)
        let model = environment.model
        XCTAssertFalse(model.settings.sceneSingleColor)
        XCTAssertTrue(model.settings.showsScenesSection)
        XCTAssertTrue(model.settings.showsPartySection)
        XCTAssertTrue(model.settings.showsPartyAdvanced,
                      "Advanced starts open: the Party pane is two columns and has room "
                      + "for it.")

        model.setSceneSingleColor(true)
        model.setScenesSectionExpanded(false)
        model.setPartySectionExpanded(false)
        model.setPartyAdvancedExpanded(false)

        let fresh = try relaunch().model
        XCTAssertTrue(fresh.settings.sceneSingleColor)
        XCTAssertFalse(fresh.settings.showsScenesSection)
        XCTAssertFalse(fresh.settings.showsPartySection)
        XCTAssertFalse(fresh.settings.showsPartyAdvanced,
                       "Someone who folds Advanced away finds it folded away next launch.")
    }

    /// The speed slider is live: it changes the scene without restarting it.
    func testTheSceneSpeedIsClampedAndCanBeDraggedWithoutPersisting() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setSceneSpeed(99)
        XCTAssertEqual(model.settings.sceneSpeed, 4)
        model.setSceneSpeed(0)
        XCTAssertEqual(model.settings.sceneSpeed, 0.25)

        model.setSceneSpeed(2, persist: false)
        XCTAssertEqual(model.settings.sceneSpeed, 2, accuracy: 0.0001)
        let stored = SettingsStore(defaults: try sharedDefaults()).load()
        XCTAssertEqual(stored.sceneSpeed, 0.25, accuracy: 0.0001,
                       "Nothing should have reached the store mid drag.")
        model.setSceneSpeed(2)
        XCTAssertEqual(SettingsStore(defaults: try sharedDefaults()).load().sceneSpeed,
                       2, accuracy: 0.0001)
    }

    /// A flash fights a scene's stream exactly the way it fights Party Mode's.
    func testIdentifyIsRefusedWhileASceneIsRunning() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.02)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        XCTAssertTrue(model.canIdentify)

        model.setSceneEnabled(true)
        XCTAssertTrue(model.isSceneRunning)
        XCTAssertFalse(model.canIdentify)

        let fake = fakeBulbs[0]
        fake.clearRecordedCommands()
        model.identify(model.bulbs[0])
        XCTAssertFalse(model.isIdentifying(model.bulbs[0]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(controlCommands(fake).contains(.turn(true)))
        XCTAssertFalse(controlCommands(fake).contains(.turn(false)))
        model.setSceneEnabled(false)
    }

    func testIdentifyIsRefusedWhilePartyModeIsRunning() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.02)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        XCTAssertTrue(model.canIdentify)

        model.setPartyModeEnabled(true)
        let running = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(running, .running)
        XCTAssertFalse(model.canIdentify)

        let fake = fakeBulbs[0]
        fake.clearRecordedCommands()
        model.identify(model.bulbs[0])
        XCTAssertFalse(model.isIdentifying(model.bulbs[0]))
        try await Task.sleep(nanoseconds: 200_000_000)
        // Party Mode only ever streams colors, so a power command here could only have
        // come from the identify that was supposed to be refused.
        XCTAssertFalse(controlCommands(fake).contains(.turn(true)))
        XCTAssertFalse(controlCommands(fake).contains(.turn(false)))
    }

    func testStartingPartyModeCancelsAnIdentifyInFlight() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        // Long enough that Party Mode certainly starts inside the flash.
        model.setIdentifyStepInterval(2)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)

        let fake = fakeBulbs[0]
        fake.clearRecordedCommands()
        model.identify(model.bulbs[0])
        XCTAssertTrue(model.isIdentifying(model.bulbs[0]))
        // The flash has sent its first two commands and is parked on the first gap.
        await waitFor(timeout: 3) { controlCommands(fake).count >= 2 }

        model.setPartyModeEnabled(true)
        XCTAssertFalse(model.isIdentifying(model.bulbs[0]))
        let running = await waitForParty(model) { $0 == .running }
        XCTAssertEqual(running, .running)

        // Past the gap the flash was parked on. A cancel that only cleared the flag
        // would let the rest of the sequence land here, on top of the stream.
        let powerCommandsAtCancel = controlCommands(fake).filter { command in
            if case .turn = command { return true }
            return false
        }.count
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let powerCommandsAfter = controlCommands(fake).filter { command in
            if case .turn = command { return true }
            return false
        }.count
        XCTAssertEqual(powerCommandsAfter, powerCommandsAtCancel,
                       "A canceled flash kept sending into the Party Mode stream.")
    }

    // MARK: Persistence
    //
    // The store level round trips live in GlowbeatSettingsTests. What these cover is the
    // whole app coming back: a second `AppModel` built on the same defaults suite and the
    // same bulbs, which is what the next launch is.

    func testEverythingTheUserChoseComesBackOnTheNextLaunch() async throws {
        let environment = try makeModel(bulbCount: 2)
        let model = environment.model
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.bulbs.count, 2)

        model.setEffect(.wave)
        model.setPalette(id: "blacklight")
        model.setPartyGate(0.42)
        model.setPartyFloor(0.3)
        model.setPartyCeiling(0.8)
        model.setScene(kind: .candle)
        model.setSceneSpeed(2.5)
        model.setMaxUpdatesPerSecond(4)
        model.setRescanInterval(180)
        model.setPartySnap(0.35)
        model.setPartyFade(0.7)
        model.setWaveTravelSpeed(4)
        model.setAlwaysReacts(true)
        model.setShowsMenuBarExtra(true)
        model.completeFirstRun()
        // The login item service is faked, so this goes through the model's own setter
        // without registering anything on the machine running the suite.
        loginItems.statusAfterRegister = .enabled
        model.setLaunchesAtLogin(true)
        XCTAssertTrue(model.settings.launchesAtLogin)

        let discovered = model.orderedBulbs
        model.setDisplayName("Kitchen", for: discovered[0])
        model.setDisplayName("Desk lamp", for: discovered[1])
        model.moveBulbs(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        // Spelled out rather than read back off the model, so an order that was never
        // written through cannot quietly agree with itself after the relaunch.
        let expectedOrder = [discovered[1].id, discovered[0].id]
        XCTAssertNotEqual(expectedOrder, discovered.map(\.id))
        XCTAssertEqual(model.orderedBulbs.map(\.id), expectedOrder)
        model.stopServices()

        let relaunched = try relaunch()
        let fresh = relaunched.model

        XCTAssertEqual(fresh.settings.effectKind, .wave)
        XCTAssertEqual(fresh.settings.paletteID, "blacklight")
        XCTAssertEqual(fresh.settings.palette.id, "blacklight")
        XCTAssertEqual(fresh.settings.sensitivity, 0.58, accuracy: 0.0001,
                       "The sensitivity comes back with the marker it is derived from.")
        XCTAssertEqual(fresh.settings.partyGate, 0.42, accuracy: 0.0001)
        XCTAssertEqual(fresh.settings.partyFloor, 0.3, accuracy: 0.0001)
        XCTAssertEqual(fresh.settings.partyCeiling, 0.8, accuracy: 0.0001)
        XCTAssertEqual(fresh.settings.partySnap, 0.35, accuracy: 0.0001)
        XCTAssertEqual(fresh.settings.partyFade, 0.7, accuracy: 0.0001)
        XCTAssertEqual(fresh.settings.waveTravelSpeed, 4, accuracy: 0.0001)
        XCTAssertTrue(fresh.settings.alwaysReacts)
        XCTAssertEqual(fresh.settings.sceneKind, .candle)
        XCTAssertEqual(fresh.settings.sceneSpeed, 2.5, accuracy: 0.0001)
        XCTAssertEqual(fresh.sceneState, .off,
                       "A remembered scene must not start itself on launch.")
        XCTAssertEqual(fresh.settings.maxUpdatesPerSecond, 4)
        XCTAssertEqual(fresh.settings.rescanInterval, 180)
        XCTAssertTrue(fresh.settings.showsMenuBarExtra)
        XCTAssertTrue(fresh.isMenuBarExtraInserted)
        XCTAssertTrue(fresh.settings.launchesAtLogin)
        XCTAssertTrue(fresh.settings.hasCompletedFirstRun)

        // Spec 4.4: launching never changes a bulb, so nothing is running yet.
        XCTAssertEqual(fresh.partyState, .off)
        XCTAssertTrue(fresh.identifyingBulbIDs.isEmpty)
        XCTAssertTrue(fresh.canIdentify)

        fresh.startServices()
        defer { fresh.stopServices() }
        await waitForBulbs(fresh, count: 2)
        XCTAssertEqual(fresh.orderedBulbs.map(\.id), expectedOrder)
        XCTAssertEqual(fresh.bulbs.map(\.id), expectedOrder)
        XCTAssertEqual(fresh.displayName(for: discovered[0]), "Kitchen")
        XCTAssertEqual(fresh.displayName(for: discovered[1]), "Desk lamp")
        // Party Mode is still off after the bulbs are back, so nothing about a launch
        // reaches them.
        XCTAssertEqual(fresh.partyState, .off)
    }

    /// The gate is written on the way out of a drag, not on every frame of one, so a
    /// drag that is still in progress when the app quits must not be what comes back.
    func testAGateStillBeingDraggedIsNotWhatComesBack() throws {
        let environment = try makeModel(bulbCount: 0)
        environment.model.setPartyGate(0.6)
        environment.model.setPartyGate(0.9, persist: false)
        XCTAssertEqual(environment.model.settings.partyGate, 0.9, accuracy: 0.0001)

        let relaunched = try relaunch()
        XCTAssertEqual(relaunched.model.settings.partyGate, 0.6, accuracy: 0.0001)
    }

    func testAFreshInstallLaunchesOnTheDocumentedDefaults() throws {
        let environment = try makeModel(bulbCount: 0)
        let model = environment.model
        XCTAssertEqual(model.settings, GlowbeatSettings.defaults)
        XCTAssertEqual(model.partyState, .off)
        XCTAssertFalse(model.settings.hasCompletedFirstRun)
        XCTAssertTrue(model.orderedBulbs.isEmpty)
    }

    /// The one test that runs the flash at the shipping speed, so "about 1.5 s" is
    /// measured rather than asserted against the constant that defines it.
    func testTheShippingFlashTakesAboutASecondAndAHalf() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        XCTAssertEqual(model.identifyStepInterval, 0.35, accuracy: 0.0001)
        let fake = fakeBulbs[0]
        let bulb = Bulb(id: "ZZ:99", sku: "H6004", endpoint: fake.endpoint())

        let started = Date()
        model.identify(bulb)
        await waitFor(timeout: 5) { !model.isIdentifying(bulb) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(model.isIdentifying(bulb))
        // Four gaps of 0.35, so the flash cannot be much under 1.4 s, and a sixth step
        // would push it past two.
        XCTAssertGreaterThan(elapsed, 1.3)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertEqual(controlCommands(fake).count, 6)
    }

    /// A bulb that has never been given a color reports black with white mode off. That
    /// is not a color to go back to, so the restore only puts the power back.
    func testIdentifyDoesNotRestoreABulbToBlack() async throws {
        let environment = try makeModel(bulbCount: 1)
        let model = environment.model
        model.setIdentifyStepInterval(0.02)
        let fake = fakeBulbs[0]
        fake.applyExternalChange(BulbState(isOn: true,
                                           brightness: 60,
                                           color: GoveeRGB(r: 0, g: 0, b: 0),
                                           colorTemperatureKelvin: 0))
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 1)
        await waitFor(timeout: 5) { model.bulbs.first?.state?.color == GoveeRGB(r: 0, g: 0, b: 0) }

        fake.clearRecordedCommands()
        let bulb = model.bulbs[0]
        model.identify(bulb)
        await waitFor(timeout: 5) { !model.isIdentifying(bulb) }

        XCTAssertEqual(controlCommands(fake),
                       [.turn(true), .color(identifyWhite),
                        .turn(false), .turn(true), .turn(false), .turn(true)])
        XCTAssertEqual(fake.currentState().color, identifyWhite)
        XCTAssertTrue(fake.currentState().isOn)
    }

    // MARK: The saved Advanced default

    /// "Save as default" takes the four values as they stand, and "Reset" puts them back
    /// through the same setters the sliders use, so a running session hears every one of
    /// them without being restarted.
    func testSavingTheAdvancedDefaultAndResettingBackToIt() throws {
        let model = try makeModel(bulbCount: 0).model
        model.setPartyFloor(0.3)
        model.setPartyCeiling(0.75)
        model.setPartySnap(0.4)
        model.setPartyFade(0.8)

        let mine = AdvancedValues(floor: 0.3, ceiling: 0.75, snap: 0.4, fade: 0.8)
        model.saveAdvancedAsDefault()
        XCTAssertEqual(model.settings.savedAdvancedDefault, mine)
        XCTAssertFalse(model.canResetAdvanced,
                       "Just after saving, the four values are the default.")
        XCTAssertFalse(model.canSaveAdvancedAsDefault)

        // Somewhere else entirely, by the other route into these four values.
        model.applyPartyPreset(.dreamy)
        XCTAssertEqual(model.settings.matchingPreset, .dreamy)
        XCTAssertTrue(model.canResetAdvanced)
        XCTAssertTrue(model.canSaveAdvancedAsDefault)

        model.resetAdvanced()
        XCTAssertEqual(model.settings.advancedValues, mine)
        XCTAssertNil(model.settings.matchingPreset, "0.3 / 0.75 / 0.4 / 0.8 is nobody's feel.")
        XCTAssertFalse(model.canResetAdvanced)

        // The four values only reach the room through the engine, and nothing on screen
        // shows that they did.
        XCTAssertEqual(model.partyEngineTiming.attack,
                       EffectTiming.attack(forSnap: 0.4), accuracy: 0.0005)
        XCTAssertEqual(model.partyEngineTiming.release,
                       EffectTiming.release(forFade: 0.8), accuracy: 0.005)
        XCTAssertEqual(model.partyEngineBrightnessRange.floor, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.partyEngineBrightnessRange.ceiling, 0.75, accuracy: 0.0001)

        // And it is a default, so it outlives the launch that made it.
        let fresh = try relaunch().model
        XCTAssertEqual(fresh.settings.savedAdvancedDefault, mine)
    }

    /// With nothing saved, Reset is what a fresh install runs on. That is Punchy, so the
    /// Feel row says Punchy afterwards rather than Custom.
    func testResettingAdvancedWithNothingSavedLandsOnPunchy() throws {
        let model = try makeModel(bulbCount: 0).model
        XCTAssertNil(model.settings.savedAdvancedDefault)
        model.applyPartyPreset(.mellow)
        XCTAssertTrue(model.canResetAdvanced)

        model.resetAdvanced()
        XCTAssertEqual(model.settings.matchingPreset, .punchy)
        XCTAssertEqual(model.settings.advancedValues, AdvancedValues(preset: .punchy))
        XCTAssertEqual(model.partyEngineBrightnessRange.floor,
                       PartyPreset.punchy.floor, accuracy: 0.0001)
        XCTAssertEqual(model.partyEngineBrightnessRange.ceiling,
                       PartyPreset.punchy.ceiling, accuracy: 0.0001)
        XCTAssertEqual(model.partyEngineTiming.attack,
                       PartyPreset.punchy.attack, accuracy: 0.0005)
        XCTAssertEqual(model.partyEngineTiming.release,
                       PartyPreset.punchy.release, accuracy: 0.005)
    }

    /// Both buttons are dimmed when pressing either of them would do nothing, which on a
    /// fresh install is the state they start in: it is what tells someone there is
    /// nothing to undo yet.
    func testTheAdvancedDefaultButtonsAreOffUntilASliderMoves() throws {
        let model = try makeModel(bulbCount: 0).model
        XCTAssertFalse(model.canResetAdvanced,
                       "A fresh install is already on its default.")
        XCTAssertFalse(model.canSaveAdvancedAsDefault)

        // Inside the tolerance is not a move: it is the last bit of a stored double.
        model.setPartyFade(PartyPreset.punchy.fade + PartyPreset.tolerance / 2)
        XCTAssertFalse(model.canResetAdvanced)

        model.setPartyFade(PartyPreset.punchy.fade + PartyPreset.tolerance * 4)
        XCTAssertTrue(model.canResetAdvanced)
        XCTAssertTrue(model.canSaveAdvancedAsDefault)

        // Saving is what makes them agree again, whatever the sliders say.
        model.saveAdvancedAsDefault()
        XCTAssertFalse(model.canResetAdvanced)
        XCTAssertFalse(model.canSaveAdvancedAsDefault)
    }

    /// A drag writes through on release, and so does a save: the default made in one
    /// launch is the default the next launch resets to.
    func testASavedAdvancedDefaultOutlivesARelaunchAndCanBeReplaced() throws {
        let model = try makeModel(bulbCount: 0).model
        model.applyPartyPreset(.tight)
        model.saveAdvancedAsDefault()

        let second = try relaunch().model
        XCTAssertEqual(second.settings.savedAdvancedDefault, AdvancedValues(preset: .tight))
        second.applyPartyPreset(.dreamy)
        second.saveAdvancedAsDefault()

        let third = try relaunch().model
        XCTAssertEqual(third.settings.savedAdvancedDefault, AdvancedValues(preset: .dreamy))
        third.applyPartyPreset(.punchy)
        third.resetAdvanced()
        XCTAssertEqual(third.settings.matchingPreset, .dreamy,
                       "Reset goes back to what was saved, not to Punchy.")
    }
}
