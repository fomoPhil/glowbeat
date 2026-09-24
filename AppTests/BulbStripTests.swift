import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The persistent bulb strip along the bottom of the window: the order it draws, the
/// reorder a dragged tile performs, the flash a tile asks for, and the positional names
/// every one of those has to agree about.
@MainActor
final class BulbStripTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var fakeBulbs: [FakeBulb] = []

    private func makeModel(bulbCount: Int) throws -> AppModel {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
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
                        controller: BulbController(socket: socket),
                        poller: StatusPoller(socket: socket, configuration: configuration),
                        frameSource: ScriptedFrameSource(),
                        tickSource: ManualTickSource(),
                        settingsStore: SettingsStore(defaults: defaults),
                        nameStore: BulbNameStore(defaults: defaults),
                        loginItems: FakeLoginItemService())
    }

    /// A model with `count` bulbs already discovered, which is what every test here needs
    /// before it can reorder anything.
    private func makeRoom(of count: Int) async throws -> AppModel {
        let model = try makeModel(bulbCount: count)
        model.startServices()
        await waitForBulbs(model, count: count)
        XCTAssertEqual(model.orderedBulbs.count, count, "Discovery did not find the room.")
        return model
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

    // MARK: One order, two views

    func testTheStripDrawsTheSameOrderTheBulbsPaneDoes() async throws {
        let model = try await makeRoom(of: 4)
        defer { model.stopServices() }
        let strip = BulbStripView(model: model)
        XCTAssertEqual(strip.tiles.map(\.id), model.orderedBulbs.map(\.id))
    }

    /// A drag lands in the one stored order, so the strip and the list cannot end up
    /// showing two different rooms. The order itself is `BulbNamingTests`.
    func testADragThroughATileMovesWhatTheStripDraws() async throws {
        let model = try await makeRoom(of: 4)
        defer { model.stopServices() }
        let before = model.orderedBulbs.map(\.id)
        model.moveBulb(withID: before[2], toIndex: 0)
        XCTAssertEqual(BulbStripView(model: model).tiles.map(\.id),
                       [before[2], before[0], before[1], before[3]])
        XCTAssertEqual(BulbStripView(model: model).tiles.map(\.id),
                       model.orderedBulbs.map(\.id),
                       "The strip and the list read one order, not two.")
    }

    /// A tile names its bulb the way every other view does, so a reorder renumbers the
    /// strip at the same moment it renumbers the list.
    func testATileNamesItsBulbTheWayTheListDoes() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        let ordered = model.orderedBulbs
        model.setDisplayName("Kitchen", for: ordered[0])
        model.moveBulb(withID: ordered[2].id, toIndex: 0)
        XCTAssertEqual(BulbStripView(model: model).tiles.map { model.displayName(for: $0) },
                       ["Bulb 1", "Kitchen", "Bulb 3"])
    }

    // MARK: Identify from a tile

    func testIdentifyFromATileFlashesThatBulb() async throws {
        let model = try await makeRoom(of: 2)
        defer { model.stopServices() }
        let bulb = model.orderedBulbs[0]
        XCTAssertTrue(model.canIdentify)
        model.identify(bulb)
        XCTAssertTrue(model.isIdentifying(bulb))
        XCTAssertFalse(model.isIdentifying(model.orderedBulbs[1]))
    }

    /// The existing rule, which the tiles inherit rather than re-decide: a flash sends one
    /// shot commands, so it may not run against a scene or Party Mode.
    func testATileCannotFlashWhileASceneOwnsTheBulbs() async throws {
        let model = try await makeRoom(of: 2)
        defer { model.stopServices() }
        model.setSceneEnabled(true)
        XCTAssertFalse(model.canIdentify)
        let bulb = model.orderedBulbs[0]
        model.identify(bulb)
        XCTAssertFalse(model.isIdentifying(bulb), "A flash started under a running scene.")
        model.setSceneEnabled(false)
    }

    // MARK: Layout

    /// Six tiles at the designed width is the room Phil has, and the strip spans the
    /// whole window rather than the pane so that they fit. More than six is the case
    /// nobody here can exercise with six fake bulbs, so what is asserted instead is that
    /// nine would overflow, which is what puts the chevrons on screen.
    func testTheStripScrollsRatherThanWraps() {
        XCTAssertEqual(BulbStripMetrics.tileWidth, 150)
        XCTAssertLessThanOrEqual(BulbStripMetrics.contentWidth(forTileCount: 6),
                                 MainWindowMetrics.designWidth,
                                 "Six tiles have to fit without scrolling at the design size.")
        XCTAssertGreaterThan(BulbStripMetrics.contentWidth(forTileCount: 9),
                             MainWindowMetrics.designWidth,
                             "Nine tiles have to overflow, which is what the chevrons are for.")
    }

    func testTheStripRendersWithARoomAndWithout() async throws {
        let model = try await makeRoom(of: 6)
        defer { model.stopServices() }
        let full = ImageRenderer(content: BulbStripView(model: model)
            .frame(width: MainWindowMetrics.designWidth))
        XCTAssertNotNil(full.nsImage)

        let tile = ImageRenderer(content: BulbStripTile(model: model,
                                                        bulb: model.orderedBulbs[0],
                                                        index: 0))
        XCTAssertNotNil(tile.nsImage)
    }

    // MARK: Helpers

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}
