import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Renders the Party panel to PNG so the look can be looked at.
///
/// These are not golden image tests: nothing here compares pixels, because a comparison
/// that fails on a system font update is a comparison nobody keeps. They assert the panel
/// renders at all, in both appearances and in every feel, and they leave the images in
/// `build/snapshots` (gitignored) for a human or an orchestrator to open. A restyle with
/// no way to see it is a restyle nobody can review.
@MainActor
final class PartySnapshotTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var fakeBulbs: [FakeBulb] = []

    /// The width the panel really gets in the window, near enough: the bulb list sets the
    /// window's minimum and the panel fills it.
    private static let panelWidth: CGFloat = 520

    /// `build/snapshots` beside the sources. Derived from this file's own path so the
    /// folder is the repo's, wherever the test bundle happens to be staged.
    private static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }

    /// A model with `bulbCount` fake bulbs on the wire. Zero is the default, because
    /// every panel snapshot but the Bulbs grid renders the same with or without them.
    private func makeModel(bulbCount: Int = 0) throws -> AppModel {
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

    /// Both appearances are first class, so both get rendered. Advanced is opened for the
    /// snapshot: the four sliders are half of what was restyled and they are folded away
    /// by default.
    func testThePanelRendersInBothAppearances() throws {
        let model = try makeModel()
        model.setPartyAdvancedExpanded(true)
        for scheme in [ColorScheme.dark, .light] {
            try write(panel(model: model, scheme: scheme),
                      named: "panel-\(name(for: scheme))")
        }
    }

    /// One image per feel, so the four presets can be compared side by side: the row
    /// highlights a different segment and the four sliders underneath it have all moved.
    func testEveryFeelRenders() throws {
        let model = try makeModel()
        model.setPartyAdvancedExpanded(true)
        for preset in PartyPreset.allCases {
            model.applyPartyPreset(preset)
            XCTAssertEqual(model.settings.matchingPreset, preset)
            try write(panel(model: model, scheme: .dark), named: "feel-\(preset.rawValue)")
        }

        // And Custom, which is what a drag off a preset leaves behind.
        model.setPartyFade(PartyPreset.punchy.fade + 0.1)
        XCTAssertNil(model.settings.matchingPreset)
        try write(panel(model: model, scheme: .dark), named: "feel-custom")
    }

    /// The row at the end of Advanced, with both buttons live. Rendered off the default
    /// on purpose: dimmed is what a fresh install shows and is the same row with nothing
    /// to press, so the image worth keeping is the one where both buttons can be used.
    func testTheAdvancedDefaultRowRenders() throws {
        let model = try makeModel()
        model.setPartyAdvancedExpanded(true)
        model.applyPartyPreset(.dreamy)
        XCTAssertTrue(model.canResetAdvanced)
        XCTAssertTrue(model.canSaveAdvancedAsDefault)
        try write(panel(model: model, scheme: .dark), named: "advanced-buttons-dark")
    }

    /// The two states that change how the panel looks rather than what it says: Wave,
    /// which adds the Travel row, and Always react, which grays the marker.
    func testTheStatesThatChangeTheLayoutRender() throws {
        let model = try makeModel()
        model.setEffect(.wave)
        try write(panel(model: model, scheme: .dark), named: "wave-travel-dark")
        model.setEffect(.pulse)
        model.setAlwaysReacts(true)
        try write(panel(model: model, scheme: .light), named: "always-react-light")
    }

    /// Spread's own control: one cell per bulb, each with the band it follows. Rendered
    /// with a real room of six so the grid is shown doing the thing it exists for, and
    /// with three of them moved off the round robin so the amber is not just a diagonal.
    func testTheSpreadBulbsGridRenders() async throws {
        let model = try makeModel(bulbCount: 6)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 6)
        XCTAssertEqual(model.orderedBulbs.count, 6, "The grid needs a room to draw.")

        let ordered = model.orderedBulbs
        model.setDisplayName("Kitchen", for: ordered[0])
        model.setDisplayName("Desk lamp", for: ordered[1])
        model.setSpreadGroup(.high, for: ordered[1].id)
        model.setSpreadGroup(.bass, for: ordered[2].id)
        model.setSpreadGroup(.high, for: ordered[4].id)
        model.setEffect(.spread)

        try write(panel(model: model, scheme: .dark), named: "spread-bulbs-dark")
    }

    /// The empty room, which is what someone sees before a scan has found anything.
    func testTheSpreadBulbsGridSaysSoWithNoBulbs() throws {
        let model = try makeModel()
        model.setEffect(.spread)
        XCTAssertTrue(model.orderedBulbs.isEmpty)
        try write(panel(model: model, scheme: .dark), named: "spread-bulbs-empty-dark")
    }

    /// The Confetti switch under the Palette grid, on. Drawn through a real window rather
    /// than `ImageRenderer`, which paints a placeholder over every AppKit control and
    /// would leave the one new control in the image unreadable.
    func testTheConfettiRowRenders() throws {
        let model = try makeModel()
        model.setPartyConfetti(true)
        XCTAssertTrue(model.settings.partyConfetti)
        try writeHosted(panel(model: model, scheme: .dark), scheme: .dark,
                        named: "party-confetti-dark")
        try writeHosted(panel(model: model, scheme: .light), scheme: .light,
                        named: "party-confetti-light")
    }

    /// Discovery crosses a real loopback socket, so this polls to a deadline and rescans
    /// rather than sleeping for a guessed interval.
    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    // MARK: Rendering

    /// The panel on the window surface it really sits on. The backdrop is the mockup's
    /// own window token, because a glass sheet rendered onto nothing shows nothing.
    private func panel(model: AppModel, scheme: ColorScheme) -> some View {
        PartyPanelView(model: model)
            .frame(width: Self.panelWidth)
            .background(scheme == .dark
                        ? Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1E / 255)
                        : Color(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF5 / 255))
            .environment(\.colorScheme, scheme)
    }

    private func name(for scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    /// Hosts the view in an offscreen window in the given appearance, lets AppKit lay it
    /// out, and writes what the window's own drawing produces, so switches, sliders and
    /// checkboxes are the real controls.
    private func writeHosted(_ view: some View, scheme: ColorScheme, named name: String) throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertGreaterThan(size.height, 0, "\(name) has no height.")
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                           "\(name) has nothing to draw into.")
        host.cacheDisplay(in: host.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]),
                                 "\(name) would not encode.")
        let directory = Self.snapshotDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("[snapshot] \(url.path)")
    }

    /// Renders at 2x and writes the PNG, then prints where it went. The path in the log
    /// is the point: it is how whoever asked for the restyle gets to see it.
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
}
