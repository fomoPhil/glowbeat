import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// One naming rule, and one order behind it.
///
/// Phil's ruling of 2026-09-16: a bulb nobody has named is called by its place in the
/// list, so dragging it somewhere else renames it and everything it passed, while a name
/// somebody typed belongs to that bulb and is never renumbered. Every view that shows a
/// bulb asks one place for the answer, so the list, the strip, the Spread grid and
/// Identify cannot end up saying different things.
@MainActor
final class BulbNamingTests: XCTestCase {

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

    // MARK: One order

    func testDraggingATileReordersTheOneSharedOrder() async throws {
        let model = try await makeRoom(of: 4)
        defer { model.stopServices() }
        let before = model.orderedBulbs.map(\.id)

        // The third tile dropped onto the first: what a drag in the strip comes to.
        model.moveBulb(withID: before[2], toIndex: 0)

        let after = model.orderedBulbs.map(\.id)
        XCTAssertEqual(after, [before[2], before[0], before[1], before[3]])
        XCTAssertEqual(model.reachableBulbs.map(\.id), after,
                       "Wave travels the list order, so a strip drag has to move it too.")
    }

    func testAReorderThroughTheStripSurvivesARelaunch() async throws {
        let model = try await makeRoom(of: 3)
        let before = model.orderedBulbs.map(\.id)
        model.moveBulb(withID: before[2], toIndex: 0)
        let after = model.orderedBulbs.map(\.id)
        model.stopServices()
        socket.stop()

        let fresh = try await makeRoom(of: 3)
        defer { fresh.stopServices() }
        XCTAssertEqual(fresh.orderedBulbs.map(\.id), after)
    }

    func testADropOnItselfChangesNothing() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        let before = model.orderedBulbs.map(\.id)
        model.moveBulb(withID: before[1], toIndex: 1)
        XCTAssertEqual(model.orderedBulbs.map(\.id), before)
    }

    func testADropCarryingAnIdNothingKnowsIsIgnored() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        let before = model.orderedBulbs.map(\.id)
        model.moveBulb(withID: "not a bulb", toIndex: 0)
        XCTAssertEqual(model.orderedBulbs.map(\.id), before)
    }

    func testADestinationOutsideTheListLandsAtTheEnd() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        let before = model.orderedBulbs.map(\.id)
        model.moveBulb(withID: before[0], toIndex: 99)
        XCTAssertEqual(model.orderedBulbs.map(\.id), [before[1], before[2], before[0]])
    }

    // MARK: Positional names

    /// Phil's ruling, 2026-09-16: a bulb nobody has named is called by its place in the
    /// list, and dragging it somewhere else renames it and everything it passed.
    func testAReorderRenumbersTheDefaultNamesAtOnce() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        var ordered = model.orderedBulbs
        XCTAssertEqual(ordered.map { model.displayName(for: $0) },
                       ["Bulb 1", "Bulb 2", "Bulb 3"])

        let third = ordered[2]
        model.moveBulb(withID: third.id, toIndex: 0)

        ordered = model.orderedBulbs
        XCTAssertEqual(ordered.map { model.displayName(for: $0) },
                       ["Bulb 1", "Bulb 2", "Bulb 3"],
                       "The names belong to the places, not to the bulbs.")
        XCTAssertEqual(model.displayName(for: third), "Bulb 1",
                       "The bulb that was third reads as the first one now.")
    }

    func testACustomNameStaysWithItsBulbThroughAReorder() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        let ordered = model.orderedBulbs
        let kitchen = ordered[2]
        model.setDisplayName("Kitchen", for: kitchen)
        XCTAssertEqual(model.displayName(for: kitchen), "Kitchen")

        model.moveBulb(withID: kitchen.id, toIndex: 0)

        XCTAssertEqual(model.displayName(for: kitchen), "Kitchen",
                       "A name someone typed is never renumbered.")
        XCTAssertEqual(model.orderedBulbs.map { model.displayName(for: $0) },
                       ["Kitchen", "Bulb 2", "Bulb 3"],
                       "The bulbs that moved down take the numbers they now sit on.")
    }

    /// The Spread grid, the strip and the list all ask one place for a name, so a reorder
    /// cannot leave two of them disagreeing.
    func testTheSpreadGridShowsTheRenumberedNames() async throws {
        let model = try await makeRoom(of: 3)
        defer { model.stopServices() }
        model.setEffect(.spread)
        let ordered = model.orderedBulbs
        model.setDisplayName("Kitchen", for: ordered[0])
        model.moveBulb(withID: ordered[2].id, toIndex: 0)

        let names = model.orderedBulbs.map { SpreadBulbCell(model: model, bulb: $0).name }
        XCTAssertEqual(names, ["Bulb 1", "Kitchen", "Bulb 3"])
        XCTAssertEqual(names, model.orderedBulbs.map { model.displayName(for: $0) })
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
