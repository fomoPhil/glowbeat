import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The window's four panes: which one is showing, what each one says about itself in the
/// sidebar, and the fact that the window lays out at the size it is designed for.
@MainActor
final class SidebarTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var fakeBulbs: [FakeBulb] = []

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

    // MARK: Which pane is showing

    func testAFreshInstallOpensOnTheBulbsPane() throws {
        let model = try makeModel()
        XCTAssertEqual(model.selectedPane, .bulbs)
    }

    func testTheChosenPaneSurvivesARelaunch() throws {
        let model = try makeModel()
        model.setSelectedPane(.schedule)
        XCTAssertEqual(model.selectedPane, .schedule)

        socket.stop()
        let fresh = try makeModel()
        XCTAssertEqual(fresh.selectedPane, .schedule,
                       "The window has to come back on the pane it was left on.")
    }

    /// A pane id from a hand edited plist, or from a build that had a fifth pane, must
    /// not leave the window showing nothing.
    func testAPaneThisBuildDoesNotKnowFallsBackToBulbs() throws {
        _ = try makeModel()
        defaults.set("holodeck", forKey: "selectedPaneID")
        socket.stop()
        let fresh = try makeModel()
        XCTAssertEqual(fresh.selectedPane, .bulbs)
    }

    func testWritingTheSamePaneTwiceChangesNothing() throws {
        let model = try makeModel()
        model.setSelectedPane(.party)
        model.setSelectedPane(.party)
        XCTAssertEqual(model.selectedPane, .party)
    }

    /// The Bulbs pane already is the list, so the strip underneath it would be a second
    /// copy of every control on screen.
    func testTheStripIsHiddenOnlyOnTheBulbsPane() {
        XCTAssertFalse(SidebarPane.bulbs.showsBulbStrip)
        for pane in SidebarPane.allCases where pane != .bulbs {
            XCTAssertTrue(pane.showsBulbStrip, "\(pane.title) has to keep the strip.")
        }
    }

    func testEveryPaneHasATitleAndASymbol() {
        XCTAssertEqual(SidebarPane.allCases.map(\.title),
                       ["Bulbs", "Party", "Scenes", "Colors", "Schedule"])
        for pane in SidebarPane.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil),
                            "\(pane.title) asks for a symbol macOS does not have.")
        }
    }

    // MARK: The status lines

    func testTheBulbsLineCountsWhatIsOn() {
        XCTAssertEqual(SidebarStatus.bulbs(total: 0, on: 0), "No bulbs")
        XCTAssertEqual(SidebarStatus.bulbs(total: 6, on: 6), "6 on")
        XCTAssertEqual(SidebarStatus.bulbs(total: 6, on: 2), "2 of 6 on")
        XCTAssertEqual(SidebarStatus.bulbs(total: 6, on: 0), "0 of 6 on")
        XCTAssertEqual(SidebarStatus.bulbs(total: 1, on: 1), "1 on")
    }

    func testThePartyLineNamesTheEffectAndTheFeel() {
        XCTAssertEqual(SidebarStatus.party(state: .off, effect: .pulse, feel: .punchy), "Off")
        XCTAssertEqual(SidebarStatus.party(state: .running, effect: .pulse, feel: .punchy),
                       "On, Pulse, Punchy")
        XCTAssertEqual(SidebarStatus.party(state: .running, effect: .wave, feel: nil),
                       "On, Wave, Custom")
        XCTAssertEqual(SidebarStatus.party(state: .paused(reason: "The Govee app took over"),
                                           effect: .glow,
                                           feel: .mellow),
                       "Paused")
    }

    func testTheScenesLineNamesTheSceneOnlyWhileItRuns() {
        XCTAssertEqual(SidebarStatus.scenes(isRunning: false, kind: .colorFlow), "Off")
        XCTAssertEqual(SidebarStatus.scenes(isRunning: true, kind: .colorFlow), "Color flow")
        XCTAssertEqual(SidebarStatus.scenes(isRunning: true, kind: .candle), "Candle")
    }

    func testTheScheduleLineNamesBothTimes() {
        var schedule = ScheduleSettings.defaults
        XCTAssertEqual(SidebarStatus.schedule(schedule, locale: Self.locale), "Off")
        schedule.isEnabled = true
        schedule.wakeTime = TimeOfDay(hour: 6, minute: 30)
        schedule.sleepTime = TimeOfDay(hour: 23, minute: 0)
        XCTAssertEqual(SidebarStatus.schedule(schedule, locale: Self.locale),
                       "Wake 6:30\u{202F}AM, sleep 11:00\u{202F}PM")
    }

    /// The lines the window really draws, rather than the pure functions underneath them.
    func testTheModelAnswersForEveryPane() throws {
        let model = try makeModel()
        XCTAssertEqual(model.sidebarStatus(for: .bulbs), "No bulbs")
        XCTAssertEqual(model.sidebarStatus(for: .party), "Off")
        XCTAssertEqual(model.sidebarStatus(for: .scenes), "Off")
        XCTAssertEqual(model.sidebarStatus(for: .colors), "Off")
        XCTAssertEqual(model.sidebarStatus(for: .schedule), "Off")

        model.setScheduleEnabled(true)
        XCTAssertTrue(model.sidebarStatus(for: .schedule).hasPrefix("Wake "),
                      "A schedule that is on has to say when.")
    }

    func testTheBulbsLineFollowsTheRoom() async throws {
        let model = try makeModel(bulbCount: 3)
        model.startServices()
        defer { model.stopServices() }
        await waitForBulbs(model, count: 3)
        XCTAssertEqual(model.sidebarStatus(for: .bulbs), "0 of 3 on",
                       "A fake bulb starts off, so the line has to say so rather than "
                       + "counting bulbs it has found.")
    }

    // MARK: Layout

    /// The window is designed to need no scrolling at this size, which is the size the
    /// mockup was drawn at and the size the snapshots are rendered at.
    func testTheDesignSizeIsNotSmallerThanTheMinimum() {
        XCTAssertGreaterThanOrEqual(MainWindowMetrics.designWidth,
                                    MainWindowMetrics.minimumWidth)
        XCTAssertGreaterThanOrEqual(MainWindowMetrics.designHeight,
                                    MainWindowMetrics.minimumHeight)
    }

    /// The widest thing in the app is a bulb row, and the sidebar takes its width off the
    /// front of the detail pane. The two together are what the minimum has to hold.
    func testABulbRowFitsTheDetailPaneAtTheMinimumWidth() {
        let detail = MainWindowMetrics.minimumWidth - MainWindowMetrics.sidebarMinimumWidth
        XCTAssertGreaterThanOrEqual(detail, BulbListMetrics.minimumWidth,
                                    "A bulb row falls off the end of the smallest window.")
    }

    func testTheWindowRendersEveryPane() throws {
        let model = try makeModel()
        for pane in SidebarPane.allCases {
            model.setSelectedPane(pane)
            let renderer = ImageRenderer(content: MainWindowView(model: model)
                .frame(width: MainWindowMetrics.designWidth,
                       height: MainWindowMetrics.designHeight))
            XCTAssertNotNil(renderer.nsImage, "The \(pane.title) pane did not lay out.")
        }
    }

    // MARK: Helpers

    private static let locale = Locale(identifier: "en_US")

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}
