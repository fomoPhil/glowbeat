import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The Colors pane: where it sits in the sidebar, what its line says, and that it lays
/// out with every swatch in the catalog on it.
@MainActor
final class ColorsPaneTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var fakeBulbs: [FakeBulb] = []

    private static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }

    private func makeModel(bulbCount: Int = 0) throws -> AppModel {
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

    // MARK: Where it sits

    /// Between Scenes and Schedule, which is the order the brief sets and the order the
    /// panes read in: the three ways to light the room, then when it happens by itself.
    func testColorsSitsBetweenScenesAndSchedule() {
        XCTAssertEqual(SidebarPane.allCases, [.bulbs, .party, .scenes, .colors, .schedule])
    }

    func testTheColorsPaneKeepsTheBulbStrip() {
        XCTAssertTrue(SidebarPane.colors.showsBulbStrip)
    }

    func testTheColorsPaneHasASymbolMacOSHas() {
        XCTAssertEqual(SidebarPane.colors.symbol, "paintpalette")
        XCTAssertNotNil(NSImage(systemSymbolName: SidebarPane.colors.symbol,
                                accessibilityDescription: nil))
    }

    // MARK: The status line

    func testTheLineNamesTheColorAndItsBrightness() {
        XCTAssertEqual(SidebarStatus.colors(applied: nil, brightness: 0.7), "Off")
        XCTAssertEqual(SidebarStatus.colors(applied: .goldenHour, brightness: 0.7),
                       "Golden hour, 70%")
        XCTAssertEqual(SidebarStatus.colors(applied: .daylight, brightness: 1),
                       "Daylight, 100%")
        XCTAssertEqual(SidebarStatus.colors(applied: .neonPink,
                                            brightness: StillColor.minimumBrightness),
                       "Neon pink, 1%")
    }

    /// The line the window really draws, rather than the pure function underneath it.
    func testTheModelAnswersForTheColorsPane() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(model.sidebarStatus(for: .colors), "Off")

        model.setStillBrightness(0.4)
        model.applyStillColor(.dusk)
        XCTAssertEqual(model.sidebarStatus(for: .colors), "Dusk, 40%")

        model.setPartyModeEnabled(true)
        XCTAssertEqual(model.sidebarStatus(for: .colors), "Off",
                       "Party Mode is repainting the room, so no color is applied.")
    }

    /// A relaunch remembers the swatch but not that it is on the bulbs, so the line has
    /// to read as the live half rather than as the stored one.
    func testTheLineIsOffAfterARelaunchEvenWithAColorRemembered() async throws {
        let model = try makeModel(bulbCount: 2)
        model.startServices()
        await waitForBulbs(model, count: 2)
        model.applyStillColor(.lavender)
        XCTAssertEqual(model.sidebarStatus(for: .colors), "Lavender, 70%")
        model.stopServices()
        socket.stop()

        let fresh = try makeModel(bulbCount: 0)
        defer { fresh.stopServices() }
        XCTAssertEqual(fresh.settings.stillColorID, "lavender")
        XCTAssertEqual(fresh.sidebarStatus(for: .colors), "Off")
    }

    // MARK: The pane itself

    /// One caption under the header, in Phil's own terms: the color stays put.
    func testThePaneSaysTheColorStays() {
        XCTAssertEqual(ColorsPanelView.caption,
                       "Pick a color and it stays until you change it.")
    }

    /// Every color in the catalog is under a group the grid walks.
    ///
    /// `ColorsPanelView` draws `StillColorGroup.allCases` and each section draws
    /// `StillColor.colors(in:)`, so this is that composition asserted directly: a color
    /// filed under a group that does not exist, or a group the pane forgot, is a swatch
    /// nobody can click.
    func testEveryColorInTheCatalogIsUnderAGroupTheGridDraws() {
        let drawn = StillColorGroup.allCases.flatMap { StillColor.colors(in: $0) }
        XCTAssertEqual(Set(drawn.map(\.id)), Set(StillColor.all.map(\.id)))
        XCTAssertEqual(drawn.count, StillColor.all.count, "A color is drawn twice.")
    }

    /// The grid really lays its swatches out, rather than drawing a heading over nothing.
    ///
    /// Measured rather than introspected: SwiftUI draws a hand rolled button into one
    /// layer, so there is no per swatch view to count. What there is is height. A section
    /// has to be at least one swatch tall, and Mood, at nine colors, has to wrap onto more
    /// rows than Whites at six when both are given the same width.
    func testEachGroupDrawsItsSwatches() throws {
        let width = MainWindowMetrics.designWidth - MainWindowMetrics.sidebarIdealWidth

        func height(_ group: StillColorGroup) throws -> Int {
            let renderer = ImageRenderer(content: StillColorGroupSection(
                group: group,
                columns: [GridItem(.adaptive(minimum: StillColorSwatch.columnWidth),
                                   spacing: 10,
                                   alignment: .top)],
                selection: nil,
                onSelect: { _ in })
                .frame(width: width))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage, "\(group.title) drew nothing.").height
        }

        for group in StillColorGroup.allCases {
            XCTAssertGreaterThan(try height(group),
                                 Int(StillColorSwatch.swatchHeight),
                                 "\(group.title) is shorter than one swatch, so it drew "
                                 + "a heading and nothing under it.")
        }
        XCTAssertGreaterThan(try height(.mood), try height(.whites),
                             "Nine colors have to wrap onto more rows than six do.")
    }

    func testThePaneRendersInBothAppearances() throws {
        let model = try makeModel()
        model.applyStillColor(.goldenHour)
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: ColorsPanelView(model: model)
                .frame(width: MainWindowMetrics.designWidth
                              - MainWindowMetrics.sidebarIdealWidth)
                .environment(\.colorScheme, scheme))
            XCTAssertNotNil(renderer.nsImage, "The pane did not lay out in \(scheme).")
        }
    }

    /// A white swatch is painted in the white it really is, not in plain white, or the
    /// Whites row would be six identical rectangles.
    func testTheWhiteSwatchesAreNotAllTheSameColor() {
        let candle = ColorConversion.swatch(for: .candle)
        let overcast = ColorConversion.swatch(for: .overcast)
        XCTAssertNotEqual(NSColor(candle), NSColor(overcast),
                          "Candle and Overcast are painted the same, so the row reads "
                          + "as one color six times.")
    }

    func testAColorSwatchIsPaintedInItsOwnColor() {
        let lava = ColorConversion.swatch(for: .lava)
        let resolved = try? XCTUnwrap(NSColor(lava).usingColorSpace(.sRGB))
        XCTAssertEqual(Int(((resolved?.redComponent ?? 0) * 255).rounded()), 0xFF)
        XCTAssertEqual(Int(((resolved?.greenComponent ?? 0) * 255).rounded()), 0x3C)
        XCTAssertEqual(Int(((resolved?.blueComponent ?? 0) * 255).rounded()), 0x0A)
    }

    /// Static and a still color do nearly the same thing, so Static says where the
    /// simpler one lives rather than being taken away in this pass.
    func testTheStaticScenePointsAtColors() {
        XCTAssertTrue(ScenesPanelView.summary(for: .fixed).contains("use Colors"),
                      ScenesPanelView.summary(for: .fixed))
        for kind in SceneKind.allCases where kind != .fixed {
            XCTAssertEqual(ScenesPanelView.summary(for: kind), kind.summary,
                           "Only Static points at the Colors pane.")
        }
    }

    /// How much of the pane the window Glowbeat opens at really shows.
    ///
    /// Twenty six swatches do not fit, and that is the whole reason the brightness slider
    /// is above the grid rather than under it: the one control you reach for after a
    /// click must not be behind the catalog. What this holds is the size of the overflow,
    /// so a catalog that doubled, or a swatch that grew, would fail here rather than
    /// quietly turning the pane into a long scroll.
    func testThePaneOverflowsTheWindowByAtMostTwoRows() throws {
        let model = try makeModel()
        let width = MainWindowMetrics.designWidth - MainWindowMetrics.sidebarIdealWidth
        let renderer = ImageRenderer(content: ColorsPanelView(model: model).frame(width: width))
        renderer.scale = 1
        let height = try XCTUnwrap(renderer.cgImage, "The pane drew nothing.").height
        let available = MainWindowMetrics.availablePaneHeight(
            windowHeight: MainWindowMetrics.defaultHeight,
            showsBulbStrip: true)

        // One row is a swatch, its name and the gaps either side of it.
        let row = StillColorSwatch.swatchHeight + StillColorSwatch.chipPadding * 2 + 22
        XCTAssertLessThanOrEqual(CGFloat(height), available + row * 2,
                                 "The pane is \(height) points against \(available) of "
                                 + "room, which is more than two rows of scrolling.")
    }

    // MARK: Snapshots

    func testTheColorsPaneSnapshots() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setStillBrightness(0.7)
        model.applyStillColor(.goldenHour)
        model.setSelectedPane(.colors)

        try write(window(model: model, scheme: .dark), named: "sidebar-colors")
        try write(window(model: model, scheme: .light), named: "sidebar-colors-light")
    }

    // MARK: Helpers

    /// The window at the size it opens at, rather than the 760 the other snapshots use:
    /// this pane is the one with a grid in it, so what is worth looking at is how much of
    /// the grid the window Glowbeat opens at really shows.
    private func window(model: AppModel, scheme: ColorScheme) -> some View {
        MainWindowView(model: model).snapshotLayout
            .frame(width: MainWindowMetrics.designWidth,
                   height: MainWindowMetrics.defaultHeight)
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
