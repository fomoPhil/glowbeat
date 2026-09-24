import XCTest
import Effects
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Applying a still color, and the rules that keep it from fighting everything else that
/// wants the same bulbs.
///
/// A still color is a one shot: three commands and then silence. So what is worth testing
/// is not a stream but an order (on, then the color, then the brightness), an exclusivity
/// (it stops Party Mode and any scene first, and they stop it), and a rate limit (the
/// brightness slider sends at most once every 150 ms while it is being dragged).
@MainActor
final class StillColorWiringTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var fakeBulbs: [FakeBulb] = []
    /// The clock the rate limiter reads, wound by hand so a test never sleeps.
    private let now = ManualDateClock(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeModel(bulbCount: Int = 2) throws -> AppModel {
        if fakeBulbs.isEmpty {
            fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        }
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        try socket.start()
        if defaults == nil {
            suiteName = "glowbeat.tests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }
        return AppModel(socket: socket,
                        discovery: BulbDiscovery(socket: socket, configuration: configuration),
                        // One send per command, so the recorded order is the order the
                        // app asked for rather than the order three repeats interleaved
                        // in.
                        controller: BulbController(socket: socket,
                                                   configuration: .init(repeatCount: 1)),
                        poller: StatusPoller(socket: socket, configuration: configuration),
                        frameSource: ScriptedFrameSource(),
                        tickSource: ManualTickSource(),
                        scheduleTickSource: ManualIntervalTicker(),
                        scheduleClock: now.reader,
                        nightShift: FakeNightShift(),
                        settingsStore: SettingsStore(defaults: defaults),
                        nameStore: BulbNameStore(defaults: defaults),
                        loginItems: FakeLoginItemService())
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        defaults = nil
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    private func makeRoom() async throws -> AppModel {
        let model = try makeModel()
        model.startServices()
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.reachableBulbs.count, 2, "The test needs a room.")
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        return model
    }

    // MARK: What reaches the bulbs

    func testApplyingAWhiteTurnsTheBulbsOnThenSendsKelvinThenBrightness() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setStillBrightness(0.5)
        // The slider sends on its own, and it sends from a task, so the recording is
        // only cleared once that has landed. Otherwise it arrives after the clear and
        // reads as the first command of the apply.
        _ = await waitForCommands(count: 1)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }

        model.applyStillColor(.daylight)

        let commands = await waitForCommands(count: 3)
        XCTAssertEqual(commands, [.turn(true), .colorTemperature(6000), .brightness(50)],
                       "On, then the color, then the brightness, in that order.")
    }

    func testApplyingAColorSendsItAsRGB() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setStillBrightness(0.7)
        _ = await waitForCommands(count: 1)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }

        model.applyStillColor(.goldenHour)

        let commands = await waitForCommands(count: 3)
        XCTAssertEqual(commands, [.turn(true),
                                  .color(GoveeRGB(r: 0xFF, g: 0xA1, b: 0x14)),
                                  .brightness(70)])
    }

    /// Every reachable bulb, not only the first: this is a room control.
    func testEveryBulbGetsTheColor() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.lava)
        _ = await waitForCommands(count: 3)

        for bulb in fakeBulbs {
            let commands = bulb.recordedCommands().filter { $0 != .devStatus && $0 != .scan }
            XCTAssertTrue(commands.contains(.color(GoveeRGB(r: 0xFF, g: 0x3C, b: 0x0A))),
                          "A bulb was left out: \(commands)")
        }
    }

    /// Nothing to send to is not a crash and not a half applied state: the selection is
    /// still recorded, so the swatch rings and the next scan lands somewhere sensible.
    func testApplyingWithNoBulbsOnTheNetworkStillRecordsTheChoice() throws {
        let model = try makeModel(bulbCount: 0)
        XCTAssertTrue(model.reachableBulbs.isEmpty)
        model.applyStillColor(.mint)
        XCTAssertEqual(model.settings.stillColorID, "mint")
        XCTAssertEqual(model.appliedStillColor, .mint)
    }

    // MARK: One driver at a time

    func testApplyingAColorStopsAScene() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setSceneEnabled(true)
        XCTAssertTrue(model.isSceneRunning)

        model.applyStillColor(.dusk)
        XCTAssertFalse(model.isSceneRunning, "A scene and a still color want the same bulbs.")
    }

    func testApplyingAColorStopsPartyMode() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setPartyModeEnabled(true)
        _ = await waitForParty(model) { $0 == .running }

        model.applyStillColor(.dusk)
        XCTAssertEqual(model.partyState, .off)
        XCTAssertFalse(model.isPartyTransitioning)
    }

    func testStartingPartyModeDropsTheAppliedColor() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.rose)
        XCTAssertEqual(model.appliedStillColor, .rose)

        model.setPartyModeEnabled(true)
        XCTAssertNil(model.appliedStillColor,
                     "Party Mode is repainting the room, so the color is not on it.")
        // The pick itself is remembered, so the pane still rings the swatch.
        XCTAssertEqual(model.settings.stillColorID, "rose")
    }

    func testStartingASceneDropsTheAppliedColor() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.rose)

        model.setSceneEnabled(true)
        XCTAssertNil(model.appliedStillColor)
        XCTAssertEqual(model.settings.stillColorID, "rose")
    }

    /// Picking Daylight, Night or Auto is a deliberate repaint of the whole room, so the
    /// still color is no longer what is up there.
    func testPickingALightModeDropsTheAppliedColor() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.rose)

        model.setLightMode(.night)
        XCTAssertNil(model.appliedStillColor)
    }

    /// Opening Glowbeat is not proof the room is still wearing the color it was left on,
    /// so the live half starts empty however the stored half reads.
    func testARelaunchRemembersThePickButNotThatItIsApplied() async throws {
        let model = try await makeRoom()
        model.applyStillColor(.ocean)
        model.stopServices()
        socket.stop()

        let fresh = try makeModel()
        defer { fresh.stopServices() }
        XCTAssertEqual(fresh.settings.stillColorID, "ocean")
        XCTAssertNil(fresh.appliedStillColor)
    }

    // MARK: The Light mode does not argue with it

    /// The schedule brief's rule, which the Colors pane inherits: a color the user picked
    /// by hand stands until the next Light transition. A transition the light mode worked
    /// out while Party Mode held the bulbs must not be flushed at the room the moment the
    /// music stops, on top of the color that was just asked for.
    func testAStillColorSettlesATransitionTheLightModeMissed() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setLightMode(.night)
        model.setPartyModeEnabled(true)
        _ = await waitForParty(model) { $0 == .running }
        // Worked out while Party Mode owns the bulbs, so it is only remembered.
        model.setLightMode(.daylight)

        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        model.applyStillColor(.blacklight)
        _ = await waitForCommands(count: 3)

        let kelvins = try XCTUnwrap(fakeBulbs.first).recordedCommands().filter {
            if case .colorTemperature = $0 { return true }
            return false
        }
        XCTAssertTrue(kelvins.isEmpty,
                      "The light mode repainted the room over the color: \(kelvins)")
    }

    // MARK: The brightness slider

    func testCommittingABrightnessPersistsItAndSends() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.warm)
        _ = await waitForCommands(count: 3)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }

        model.setStillBrightness(0.35)
        XCTAssertEqual(model.settings.stillBrightness, 0.35, accuracy: 0.000_001)
        let commands = await waitForCommands(count: 1)
        XCTAssertEqual(commands, [.brightness(35)])

        socket.stop()
        let fresh = try makeModel()
        defer { fresh.stopServices() }
        XCTAssertEqual(fresh.settings.stillBrightness, 0.35, accuracy: 0.000_001)
    }

    /// The same drag and commit split the Party sliders use: the room follows the drag,
    /// the store is only written when it ends.
    func testADragDoesNotWriteToTheStore() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.warm)

        model.setStillBrightness(0.2, persist: false)
        XCTAssertEqual(model.settings.stillBrightness, 0.2, accuracy: 0.000_001)

        socket.stop()
        let fresh = try makeModel()
        defer { fresh.stopServices() }
        XCTAssertEqual(fresh.settings.stillBrightness, StillColor.defaultBrightness,
                       accuracy: 0.000_001)
    }

    /// A drag produces a value on every frame, and these bulbs are on Wi-Fi with no
    /// retries. One send every 150 ms is what keeps a drag from being a flood.
    func testADragSendsAtMostOnceEveryHundredAndFiftyMilliseconds() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.warm)
        _ = await waitForCommands(count: 3)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        // The apply has just sent a brightness of its own, so the window it opened has
        // to run out before the drag below is a drag rather than a second send inside
        // the same window. Well past it rather than exactly on it: a `Date` this far
        // from its reference cannot hold 150 ms exactly, and an advance of precisely the
        // interval can land a hair inside the window it was meant to clear.
        now.advance(by: 1)

        // The first frame of the drag goes out at once: waiting 150 ms to react to a
        // drag is what makes a slider feel broken.
        model.setStillBrightness(0.10, persist: false)
        var commands = await waitForCommands(count: 1)
        XCTAssertEqual(commands, [.brightness(10)])

        // Twenty more frames inside the window, none of which reach a bulb.
        for step in 1...20 {
            now.advance(by: 0.005)
            model.setStillBrightness(0.10 + Double(step) * 0.01, persist: false)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        commands = brightnessCommands()
        XCTAssertEqual(commands, [.brightness(10)],
                       "The drag flooded the bulbs: \(commands)")

        // Past the window, the next frame lands.
        now.advance(by: 0.2)
        model.setStillBrightness(0.44, persist: false)
        commands = await waitForCommands(count: 2)
        XCTAssertEqual(commands, [.brightness(10), .brightness(44)])
    }

    /// The release always lands, whether or not it falls inside a window the drag has
    /// already spent. Otherwise the room keeps the second to last value of the drag.
    func testTheReleaseAlwaysSendsEvenInsideTheWindow() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.warm)
        _ = await waitForCommands(count: 3)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }

        now.advance(by: 1)
        model.setStillBrightness(0.10, persist: false)
        _ = await waitForCommands(count: 1)
        now.advance(by: 0.01)
        model.setStillBrightness(0.11)

        let commands = await waitForCommands(count: 2)
        XCTAssertEqual(commands, [.brightness(10), .brightness(11)])
    }

    func testDraggingTheBrightnessKeepsTheColorApplied() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.applyStillColor(.ice)
        model.setStillBrightness(0.3, persist: false)
        now.advance(by: 0.2)
        model.setStillBrightness(0.3)
        XCTAssertEqual(model.appliedStillColor, .ice)
    }

    /// Party Mode is streaming colors at these bulbs. A brightness command in the middle
    /// of that is the app fighting itself.
    func testTheBrightnessSliderDoesNotSendWhilePartyModeRuns() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setPartyModeEnabled(true)
        _ = await waitForParty(model) { $0 == .running }
        // Party Mode's own full brightness, sent as it starts, is not the slider.
        let bulbs = fakeBulbs
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !bulbs.allSatisfy({ $0.recordedCommands().contains(.brightness(100)) }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }

        model.setStillBrightness(0.25)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(brightnessCommands().isEmpty,
                      "The slider wrote over the stream: \(brightnessCommands())")
        // It is still remembered, so the next color picked uses it.
        XCTAssertEqual(model.settings.stillBrightness, 0.25, accuracy: 0.000_001)
    }

    func testTheBrightnessIsClampedOnTheWayIn() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setStillBrightness(4)
        XCTAssertEqual(model.settings.stillBrightness, 1)
        model.setStillBrightness(-1)
        XCTAssertEqual(model.settings.stillBrightness, StillColor.minimumBrightness)
    }

    // MARK: Helpers

    /// Every command the first fake bulb was sent, with the scan and status traffic that
    /// runs underneath everything taken out.
    private func commands() -> [FakeBulb.Command] {
        (fakeBulbs.first?.recordedCommands() ?? []).filter { $0 != .scan && $0 != .devStatus }
    }

    private func brightnessCommands() -> [FakeBulb.Command] {
        commands().filter {
            if case .brightness = $0 { return true }
            return false
        }
    }

    @discardableResult
    private func waitForCommands(count: Int,
                                 timeout: TimeInterval = 3) async -> [FakeBulb.Command] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if commands().count >= count { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return commands()
    }

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
}
