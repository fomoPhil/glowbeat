import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The Colors section in the menu bar popover: the same 26 colors as the pane, small
/// enough to sit between the All bulbs block and Party Mode, and the one slider that now
/// has two jobs.
@MainActor
final class MenuBarColorsTests: XCTestCase {

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

    private static var sectionSourcePath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/MenuBarColorsSection.swift")
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

    // MARK: One catalog, drawn twice

    /// The popover's grid is the pane's catalog, in the pane's order, with nothing added
    /// and nothing dropped. A second list of colors living in the menu bar file is the
    /// failure this is here to catch.
    func testTheGridDrawsEveryColorInTheCatalogOnceAndInOrder() {
        let drawn = MenuBarColorsSection.rows.flatMap { StillColor.colors(in: $0) }
        XCTAssertEqual(drawn.map(\.id), StillColor.all.map(\.id))
        XCTAssertEqual(drawn.count, 26)
    }

    /// The rows are the catalog's own four groups, in the catalog's own order, so the
    /// whites cluster at the top the way they do in the pane.
    func testTheRowsAreTheCatalogsOwnFourGroups() {
        XCTAssertEqual(MenuBarColorsSection.rows, StillColorGroup.allCases)
        XCTAssertEqual(MenuBarColorsSection.rows.count, 4)
    }

    /// No color values are written down a second time in the menu bar file.
    ///
    /// The single source of truth rule, enforced against the source rather than against
    /// the behavior: a copied hex or a copied Kelvin would pass every other test in this
    /// file right up until somebody edited one of the two lists.
    func testTheMenuBarFileHoldsNoSecondCatalog() throws {
        let source = try String(contentsOf: Self.sectionSourcePath, encoding: .utf8)
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("0x"),
                       "A hex color literal in the menu bar file is a second catalog.")
        XCTAssertFalse(code.contains("kelvin:"),
                       "A Kelvin in the menu bar file is a second catalog.")
        XCTAssertTrue(code.contains("StillColor.colors(in:"),
                      "The grid should be reading the catalog, not a list of its own.")
    }

    // MARK: It fits, and it can be hit

    /// The widest row is Mood's nine, and it has to fit inside the popover with its
    /// padding taken off, or the grid clips at the edge of the window.
    func testTheWidestRowFitsThePopover() {
        XCTAssertEqual(MenuBarColorsSection.widestRow, 9,
                       "Mood is the widest group, at nine colors.")
        let available = MenuBarContentView.popoverWidth
            - MenuBarContentView.contentPadding * 2
        XCTAssertLessThanOrEqual(MenuBarColorsSection.gridWidth, available,
                                 "The grid is \(MenuBarColorsSection.gridWidth) points "
                                 + "against \(available) of room.")
    }

    /// 320, and not the 280 the popover used to be: nine swatches, their hit areas and
    /// the gaps between them do not fit in the old width.
    func testThePopoverWasWidenedBecauseTheGridNeededIt() {
        XCTAssertEqual(MenuBarContentView.popoverWidth, 320)
        XCTAssertGreaterThan(MenuBarColorsSection.gridWidth,
                             280 - MenuBarContentView.contentPadding * 2,
                             "If the grid still fit in 280, the popover should not have "
                             + "been widened.")
    }

    /// A 40 point target is impossible at this size, so the floor is the one the brief
    /// set: every swatch is clickable over at least 28 by 24.
    func testEveryHitAreaIsAtLeastTwentyEightByTwentyFour() {
        XCTAssertGreaterThanOrEqual(MenuBarColorsSection.cellWidth, 28)
        XCTAssertGreaterThanOrEqual(MenuBarColorsSection.cellHeight, 24)
    }

    /// And no two of them touch, in either direction, so a click near an edge cannot land
    /// on the wrong color.
    func testHitAreasDoNotOverlap() {
        XCTAssertGreaterThan(MenuBarColorsSection.spacing, 0,
                             "Zero spacing puts two hit areas edge to edge.")
        XCTAssertGreaterThan(MenuBarColorsSection.rowSpacing, 0,
                             "Zero row spacing puts two hit areas edge to edge.")
        let row = StillColorGroup.allCases.map { StillColor.colors(in: $0).count }.max() ?? 0
        let pitch = MenuBarColorsSection.cellWidth + MenuBarColorsSection.spacing
        XCTAssertEqual(MenuBarColorsSection.gridWidth,
                       pitch * CGFloat(row) - MenuBarColorsSection.spacing,
                       "The grid width has to be the pitch the cells really lay out at.")
    }

    func testTheSwatchIsTheSizeTheBriefAsksFor() {
        XCTAssertEqual(MenuBarColorsSection.swatchWidth, 26)
        XCTAssertEqual(MenuBarColorsSection.swatchHeight, 18)
        XCTAssertEqual(MenuBarColorsSection.swatchRadius, 6)
        XCTAssertEqual(MenuBarColorsSection.spacing, 4)
    }

    /// The gaps read even even though the numbers are not, because the hit area is 2
    /// points taller than the swatch on each side and only 1 point wider on each side.
    func testTheGapsBetweenSwatchesLookTheSameInBothDirections() {
        let alongARow = MenuBarColorsSection.spacing
            + (MenuBarColorsSection.cellWidth - MenuBarColorsSection.swatchWidth)
        let betweenRows = MenuBarColorsSection.rowSpacing
            + (MenuBarColorsSection.cellHeight - MenuBarColorsSection.swatchHeight)
        XCTAssertLessThanOrEqual(abs(alongARow - betweenRows), 2,
                                 "The visible gaps are \(alongARow) along a row and "
                                 + "\(betweenRows) between rows.")
    }

    /// Concentric: the ring's radius is the swatch's radius plus the gap between them,
    /// which is the same rule every other nested shape in the app follows.
    func testTheRingIsConcentricWithTheSwatch() {
        let gap = (MenuBarColorsSection.cellWidth - MenuBarColorsSection.swatchWidth) / 2
        XCTAssertEqual(MenuBarColorsSection.ringRadius,
                       MenuBarColorsSection.swatchRadius + gap)
    }

    /// The four rows have to fit under the header without the popover growing past what a
    /// menu bar window sensibly shows.
    func testTheGridIsFourRowsTall() {
        let pitch = MenuBarColorsSection.cellHeight + MenuBarColorsSection.rowSpacing
        XCTAssertEqual(MenuBarColorsSection.gridHeight,
                       pitch * 4 - MenuBarColorsSection.rowSpacing)
    }

    // MARK: What the swatches are painted with

    /// The same Kelvin tint the pane paints, so Candle and Overcast are not two identical
    /// little rectangles in the menu bar.
    func testTheWhitesArePaintedWithTheirKelvinTint() {
        XCTAssertEqual(NSColor(MenuBarColorSwatch.fill(for: .candle)),
                       NSColor(ColorConversion.approximateWhite(kelvin: 2700)))
        XCTAssertNotEqual(NSColor(MenuBarColorSwatch.fill(for: .candle)),
                          NSColor(MenuBarColorSwatch.fill(for: .overcast)),
                          "Candle and Overcast are painted the same.")
    }

    /// And a color is its own channels, through the same conversion the pane uses.
    func testAColorIsPaintedInItsOwnChannels() throws {
        let resolved = try XCTUnwrap(NSColor(MenuBarColorSwatch.fill(for: .lava))
            .usingColorSpace(.sRGB))
        XCTAssertEqual(Int((resolved.redComponent * 255).rounded()), 0xFF)
        XCTAssertEqual(Int((resolved.greenComponent * 255).rounded()), 0x3C)
        XCTAssertEqual(Int((resolved.blueComponent * 255).rounded()), 0x0A)
    }

    /// There are no names under these swatches, so the tooltip is the only place the name
    /// is written. A white says which white it is, because two neighboring whites cannot
    /// show a thousand Kelvin on their own at 26 points.
    func testTheTooltipNamesEveryColorAndTheKelvinOfAWhite() {
        XCTAssertEqual(MenuBarColorSwatch.help(for: .warm), "Warm, 3000 K")
        XCTAssertEqual(MenuBarColorSwatch.help(for: .goldenHour), "Golden hour")
        for color in StillColor.all {
            XCTAssertTrue(MenuBarColorSwatch.help(for: color).hasPrefix(color.name),
                          "\(color.name) has a tooltip that does not name it.")
        }
    }

    // MARK: The readout beside the header

    /// The live half, not the remembered one: the popover says what the room is wearing,
    /// the same word the sidebar uses when it is wearing nothing.
    func testTheReadoutNamesTheAppliedColorAndOtherwiseReadsOff() {
        XCTAssertEqual(MenuBarColorsSection.readout(applied: nil), "Off")
        XCTAssertEqual(MenuBarColorsSection.readout(applied: .goldenHour), "Golden hour")
    }

    func testTheReadoutFollowsTheModel() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(MenuBarColorsSection.readout(applied: model.appliedStillColor), "Off")

        model.applyStillColor(.dusk)
        XCTAssertEqual(MenuBarColorsSection.readout(applied: model.appliedStillColor), "Dusk")

        model.setPartyModeEnabled(true)
        XCTAssertEqual(MenuBarColorsSection.readout(applied: model.appliedStillColor), "Off",
                       "Party Mode repaints the room, so no color is applied.")
    }

    /// Clicking a swatch in the popover is the same one shot the pane fires: it rings the
    /// swatch, claims the room, and is given up the moment Party Mode takes the bulbs.
    func testPickingFromThePopoverRingsTheSwatchAndClaimsTheRoom() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)

        model.applyStillColor(.mint)
        XCTAssertEqual(model.settings.stillColorID, "mint",
                       "The grid rings whatever the pane rings.")
        XCTAssertEqual(model.appliedStillColor, .mint)

        model.setPartyModeEnabled(true)
        XCTAssertNil(model.appliedStillColor)
        XCTAssertEqual(model.settings.stillColorID, "mint",
                       "The pick is a memory of a choice and survives.")
    }

    // MARK: The one slider with two jobs

    /// They really are two stores. The All bulbs slider fires a raw brightness command
    /// and remembers nothing; the Colors brightness is a persisted setting. This is why
    /// the popover's slider has to choose which one it is moving.
    func testTheAllBulbsBrightnessAndTheStillBrightnessAreTwoDifferentStores() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)
        let before = model.settings.stillBrightness

        model.setBrightness(30, for: nil)
        XCTAssertEqual(model.settings.stillBrightness, before,
                       "The All bulbs command wrote the Colors brightness.")

        model.setStillBrightness(0.3)
        XCTAssertEqual(model.settings.stillBrightness, 0.3, accuracy: 0.0001)
    }

    func testTheSliderDrivesAllBulbsUntilAColorIsApplied() {
        XCTAssertEqual(MenuBarContentView.brightnessTarget(appliedStillColor: nil),
                       .allBulbs)
        XCTAssertEqual(MenuBarContentView.brightnessTarget(appliedStillColor: .lavender),
                       .stillColor)
    }

    /// Through the model, in the two transitions that matter: a color lands and the
    /// slider takes over the still brightness; something else repaints the room and the
    /// slider goes back to being the raw All bulbs command.
    func testTheSliderFollowsTheRoomThroughTheModel() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)
        XCTAssertEqual(MenuBarContentView.brightnessTarget(
            appliedStillColor: model.appliedStillColor), .allBulbs)

        model.applyStillColor(.ocean)
        XCTAssertEqual(MenuBarContentView.brightnessTarget(
            appliedStillColor: model.appliedStillColor), .stillColor)

        model.setPartyModeEnabled(true)
        XCTAssertEqual(MenuBarContentView.brightnessTarget(
            appliedStillColor: model.appliedStillColor), .allBulbs)
    }

    /// The Colors brightness has a one percent floor, so a drag to the bottom with a
    /// color on the room settles at 1 rather than printing a 0 the bulbs never went to.
    func testACommitToTheBottomWithAColorAppliedSettlesAtOnePercent() {
        XCTAssertEqual(MenuBarContentView.settledPercent(0, target: .stillColor), 1)
        XCTAssertEqual(MenuBarContentView.settledPercent(0.4, target: .stillColor), 1)
        XCTAssertEqual(MenuBarContentView.settledPercent(100, target: .stillColor), 100)
        XCTAssertEqual(MenuBarContentView.settledPercent(70.4, target: .stillColor), 70)
    }

    /// With nothing applied it is the old All bulbs slider, which may go to zero because
    /// zero there is a command the user meant.
    func testACommitWithNoColorAppliedKeepsTheWholePercentIncludingZero() {
        XCTAssertEqual(MenuBarContentView.settledPercent(0, target: .allBulbs), 0)
        XCTAssertEqual(MenuBarContentView.settledPercent(70.4, target: .allBulbs), 70)
        XCTAssertEqual(MenuBarContentView.settledPercent(100, target: .allBulbs), 100)
    }

    /// What the slider should read when the popover opens on a room already wearing a
    /// color: the still brightness, as whole percent, not the 100 it starts life at.
    func testTheSliderReadsTheStillBrightnessOnceAColorIsApplied() async throws {
        let model = try makeModel(bulbCount: 2)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 2)
        model.setStillBrightness(0.45)
        model.applyStillColor(.rose)

        XCTAssertEqual(MenuBarContentView.syncedPercent(appliedStillColor: model.appliedStillColor,
                                                        stillBrightness: model.settings.stillBrightness,
                                                        current: 100),
                       45)
        XCTAssertEqual(MenuBarContentView.syncedPercent(appliedStillColor: nil,
                                                        stillBrightness: model.settings.stillBrightness,
                                                        current: 100),
                       100,
                       "With nothing applied the slider keeps whatever it was showing.")
    }

    // MARK: No tick marks

    /// The popover is one of the two places `SliderTickTests` already walks, and it now
    /// has a Colors grid above its slider. Held here too, at the real popover width, so
    /// a step put back on this slider fails in the file that changed it.
    func testThePopoverDrawsNoSliderTickMarks() throws {
        let model = try makeModel()
        for slider in Self.sliders(in: MenuBarContentView(model: model)) {
            XCTAssertEqual(slider.numberOfTickMarks, 0,
                           "The popover draws a slider with \(slider.numberOfTickMarks) "
                           + "tick marks.")
        }
    }

    // MARK: It lays out

    func testTheSectionRendersInBothAppearances() throws {
        let model = try makeModel()
        model.applyStillColor(.tangerine)
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: MenuBarColorsSection(model: model)
                .frame(width: MenuBarContentView.popoverWidth
                              - MenuBarContentView.contentPadding * 2)
                .environment(\.colorScheme, scheme))
            XCTAssertNotNil(renderer.nsImage, "The section did not lay out in \(scheme).")
        }
    }

    func testTheWholePopoverStillRenders() throws {
        let model = try makeModel()
        model.applyStillColor(.goldenHour)
        let renderer = ImageRenderer(content: MenuBarContentView(model: model))
        XCTAssertNotNil(renderer.nsImage)
    }

    // MARK: Snapshots

    func testTheMenuBarColorsSnapshots() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setStillBrightness(0.7)
        model.applyStillColor(.goldenHour)

        try write(popover(model: model, scheme: .dark), named: "menubar-colors")
        try write(popover(model: model, scheme: .light), named: "menubar-colors-light")
    }

    // MARK: Helpers

    private func popover(model: AppModel, scheme: ColorScheme) -> some View {
        MenuBarContentView(model: model)
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

    /// Every `NSSlider` in the real AppKit tree the popover builds. Hosted in a window and
    /// laid out, because an `NSHostingView` builds no platform subviews until it has both.
    private static func sliders(in view: some View) -> [NSSlider] {
        let size = NSSize(width: MenuBarContentView.popoverWidth, height: 900)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        var found: [NSSlider] = []
        func walk(_ view: NSView) {
            if let slider = view as? NSSlider { found.append(slider) }
            for subview in view.subviews { walk(subview) }
        }
        walk(host)
        return found
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
