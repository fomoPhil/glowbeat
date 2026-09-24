import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Renders the whole window, one image per pane, at the size the layout was drawn for.
///
/// Not golden images: nothing here compares pixels, because a comparison that fails on a
/// system font update is a comparison nobody keeps. They prove every pane lays out, they
/// prove the Party pane fits the window it was designed for with everything expanded, and
/// they leave the PNGs in `build/snapshots` for a human to open.
@MainActor
final class SidebarSnapshotTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var fakeBulbs: [FakeBulb] = []

    private static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }

    private func makeModel(bulbCount: Int) throws -> AppModel {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    /// A real room of six, because every pane but Schedule draws the strip and the strip
    /// is the point of half of this.
    private func makeRoom() async throws -> AppModel {
        let model = try makeModel(bulbCount: 6)
        model.startServices()
        await waitForBulbs(model, count: 6)
        XCTAssertEqual(model.orderedBulbs.count, 6, "The snapshots need a room to draw.")
        let ordered = model.orderedBulbs
        model.setDisplayName("Kitchen", for: ordered[2])
        model.setDisplayName("Desk lamp", for: ordered[4])
        model.setScheduleEnabled(true)
        model.setWakeTime(TimeOfDay(hour: 6, minute: 30))
        model.setSleepTime(TimeOfDay(hour: 23, minute: 0))
        model.setWakeRamp(minutes: 15)
        model.setSleepRamp(minutes: 20)
        model.setWakeBrightness(70)
        model.setPartyAdvancedExpanded(true)
        return model
    }

    func testEveryPaneRendersAtTheDesignSize() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        for pane in SidebarPane.allCases {
            model.setSelectedPane(pane)
            try write(window(model: model, scheme: .dark),
                      named: "sidebar-\(pane.rawValue)")
        }

        // One light pass, on the pane with the most going on in it.
        model.setSelectedPane(.party)
        try write(window(model: model, scheme: .light), named: "sidebar-party-light")
    }

    /// The claim the layout is built on: with Advanced open, the Party pane needs no
    /// scroller in the window Glowbeat opens at. Measured by rendering the pane's content
    /// at the width the detail column really gives it and comparing its natural height
    /// with the room left over once the title bar, the pane header, the bulb strip and
    /// the footer have taken theirs.
    ///
    /// The window opens taller than the mockup because of this measurement, not in spite
    /// of it: the 760 the mockup was drawn at leaves the Party pane 27 points short.
    func testThePartyPaneFitsTheWindowItOpensAt() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        model.setSelectedPane(.party)
        XCTAssertTrue(model.settings.showsPartyAdvanced, "Measured with Advanced open.")

        let width = MainWindowMetrics.designWidth - MainWindowMetrics.sidebarIdealWidth
        let available = MainWindowMetrics.availablePaneHeight(
            windowHeight: MainWindowMetrics.defaultHeight,
            showsBulbStrip: true)
        XCTAssertGreaterThan(available, 0)

        let renderer = ImageRenderer(content: MainWindowView(model: model)
            .paneContent(width: width))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "The Party pane rendered nothing.")
        XCTAssertLessThanOrEqual(CGFloat(image.height), available,
                                 "The Party pane is \(image.height) points tall and only "
                                 + "\(available) fit, so the window Glowbeat opens at "
                                 + "would scroll.")
    }

    /// Two columns rather than one is what makes the pane fit at all, so the fact that it
    /// is shorter is asserted rather than left to the eye.
    func testTwoColumnsAreMuchShorterThanOne() async throws {
        let model = try await makeRoom()
        defer { model.stopServices() }
        let width = MainWindowMetrics.designWidth - MainWindowMetrics.sidebarIdealWidth

        func height(_ layout: PartyPanelView.Layout) throws -> Int {
            let renderer = ImageRenderer(content: PartyPanelView(model: model,
                                                                 includesToggle: false,
                                                                 layout: layout)
                .frame(width: width))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage).height
        }

        let columns = try height(.columns)
        let single = try height(.single)
        XCTAssertLessThan(columns, single - 300,
                          "Two columns are \(columns) points and one is \(single).")
    }

    // MARK: Rendering

    private func window(model: AppModel, scheme: ColorScheme) -> some View {
        MainWindowView(model: model).snapshotLayout
            .frame(width: MainWindowMetrics.designWidth,
                   height: MainWindowMetrics.designHeight)
            .background(scheme == .dark
                        ? Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1E / 255)
                        : Color(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF5 / 255))
            .environment(\.colorScheme, scheme)
    }

    private func write(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) rendered nothing.")
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let directory = Self.snapshotDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let representation = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]),
                                 "\(name) would not encode.")
        try data.write(to: url)
        print("[snapshot] \(url.path)")
    }

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}
