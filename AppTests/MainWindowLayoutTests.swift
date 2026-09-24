import XCTest
import AppKit
import AudioTap
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// The real main window, hosted in a real `NSWindow` and laid out by AppKit, with every
/// banner the window can show, on every pane.
///
/// Phil, 2026-09-22: "if the lights fade to zero, then you get that UI bug but when music
/// starts playing again, then the whole UI shows properly." The sidebar went blank, the
/// pane header, the bulb strip and the footer disappeared, and the Party pane's content
/// started half way down, under the title bar. Three seconds of silence is what the audio
/// tap reports as `.deniedOrSilent`, which raises the `.audioDenied` banner at the top of
/// the pane, and the banner is what took the window apart.
///
/// `snapshotLayout` could never have caught it: it is a hand built `HStack` drawn by
/// `ImageRenderer`, with no `NavigationSplitView`, no `NSSplitView` and no window. The
/// bug lived in the minimum size AppKit asks the split view's detail column for, so this
/// suite hosts `MainWindowView` itself and reads the frames AppKit settles on.
@MainActor
final class MainWindowLayoutTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var fakeBulbs: [FakeBulb] = []
    private var windows: [NSWindow] = []

    /// Phil's window when he took the screenshot, near enough, and the smallest one
    /// Glowbeat allows.
    private static let windowSizes = [
        NSSize(width: 1000, height: 700),
        NSSize(width: MainWindowMetrics.minimumWidth, height: MainWindowMetrics.minimumHeight),
    ]

    private struct Environment {
        var model: AppModel
        var source: ScriptedFrameSource
    }

    private func makeModel(bulbCount: Int,
                           replyPort: UInt16 = 0,
                           startsSocket: Bool = true) throws -> Environment {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        let configuration = LANConfiguration(replyPort: replyPort,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        socket = LANSocket(configuration: configuration)
        if startsSocket {
            try socket.start()
        }
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let source = ScriptedFrameSource()
        let model = AppModel(socket: socket,
                             discovery: BulbDiscovery(socket: socket,
                                                      configuration: configuration),
                             controller: BulbController(socket: socket),
                             poller: StatusPoller(socket: socket,
                                                  configuration: configuration,
                                                  interval: 0.2),
                             frameSource: source,
                             tickSource: ManualTickSource(),
                             settingsStore: SettingsStore(defaults: defaults),
                             nameStore: BulbNameStore(defaults: defaults),
                             loginItems: FakeLoginItemService())
        // The first run sheet is a window of its own and is not what is being measured.
        model.completeFirstRun()
        return Environment(model: model, source: source)
    }

    /// Six bulbs found and Party Mode running, which is the room Phil was in.
    ///
    /// The tap opens the way `SystemAudioTap` does, reporting nothing until it hears a
    /// frame. Since 2026-09-22 silence only raises the audio banner in a session that
    /// has never heard anything, and that banner is what the audio cases below measure.
    private func makePartyRoom() async throws -> Environment {
        let environment = try makeModel(bulbCount: 6)
        environment.source.setPermissionOnStart(.unknown)
        let model = environment.model
        model.startServices()
        await waitForBulbs(model, count: 6)
        XCTAssertEqual(model.bulbs.count, 6, "Discovery did not find the room.")
        model.setPartyModeEnabled(true)
        await waitFor { model.partyState == .running }
        XCTAssertEqual(model.partyState, .running)
        return environment
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: No banner

    /// The control: with nothing to say, every pane fits both windows. This passed
    /// before the fix too, and has to go on passing after it.
    func testEveryPaneFitsTheWindowWithNoBanner() async throws {
        let environment = try await makePartyRoom()
        let model = environment.model
        defer { model.stopServices() }
        XCTAssertNil(model.banner)

        assertEveryPaneFits(model, banner: "no banner")
    }

    // MARK: Every banner

    /// Phil's bug, exactly: Party Mode running on the Party pane, then silence.
    func testTheAudioBannerThatSilenceRaisesKeepsTheWindowInsideItself() async throws {
        let environment = try await makePartyRoom()
        let model = environment.model
        defer { model.stopServices() }
        model.setSelectedPane(.party)

        // What `SystemAudioTap` reports after three seconds of nothing.
        environment.source.emitPermission(.deniedOrSilent)
        await waitFor { model.banner == .audioDenied }
        XCTAssertEqual(model.banner, .audioDenied)

        assertEveryPaneFits(model, banner: "audioDenied")
    }

    func testThePausedBannerKeepsTheWindowInsideItself() async throws {
        let environment = try await makePartyRoom()
        let model = environment.model
        defer { model.stopServices() }

        // The session's baseline is its first status report, so give it one before the
        // phone moves anything. Party Mode polls every second. It also sets every bulb to
        // full brightness as it starts, and this controller repeats that a second and two
        // seconds later the way the app's does, so a phone dimming the bulb before then
        // would simply be put back.
        try await Task.sleep(nanoseconds: 2_600_000_000)
        var changed = fakeBulbs[0].currentState()
        changed.brightness = 12
        fakeBulbs[0].applyExternalChange(changed)

        await waitFor(timeout: 8) {
            if case .partyPaused = model.banner { return true }
            return false
        }
        guard case .partyPaused = model.banner else {
            return XCTFail("Party Mode never paused, so the banner is \(String(describing: model.banner)).")
        }

        assertEveryPaneFits(model, banner: "partyPaused")
    }

    /// `.noBulbs` is left off the Bulbs pane on purpose, and the Bulbs pane is still
    /// measured here: its empty list is the thing standing in for the banner there.
    func testTheNoBulbsBannerKeepsTheWindowInsideItself() throws {
        let model = try makeModel(bulbCount: 0).model
        XCTAssertEqual(model.banner, .noBulbs)

        assertEveryPaneFits(model, banner: "noBulbs")
    }

    /// The longest message any banner carries.
    func testTheNetworkBannerKeepsTheWindowInsideItself() throws {
        let blocker = try XCTUnwrap(BlockedPort(), "Could not bind a port to block.")
        defer { blocker.close() }
        let model = try makeModel(bulbCount: 0,
                                  replyPort: blocker.port,
                                  startsSocket: false).model
        model.startServices()
        defer { model.stopServices() }
        XCTAssertEqual(model.banner, .networkUnavailable)

        assertEveryPaneFits(model, banner: "networkUnavailable")
    }

    // MARK: What the pane shows never feeds the window's minimum

    /// The structural half of the fix. The window's smallest size is set in one place,
    /// `MainWindowMetrics`, and nothing the detail column happens to be showing may add
    /// to it: not a banner, not a longer sentence in one someday, not a pane header that
    /// grows a second line. So the detail column reports the same minimum height to
    /// AppKit with a banner as without one. Every banner is the same view in the same
    /// slot, so the audio banner, Phil's, stands for all four.
    ///
    /// Bounding the banner's text is what fixed Phil's window. This is what stops the
    /// next unbounded view above the scroller from taking it apart the same way.
    func testNoBannerChangesTheMinimumHeightTheDetailColumnAsksFor() async throws {
        let environment = try await makePartyRoom()
        let model = environment.model
        defer { model.stopServices() }
        model.setSelectedPane(.party)
        XCTAssertNil(model.banner)
        let size = Self.windowSizes[0]
        let withoutBanner = try detailMinimumHeight(model, size: size)

        environment.source.emitPermission(.deniedOrSilent)
        await waitFor { model.banner == .audioDenied }
        XCTAssertEqual(model.banner, .audioDenied)
        let withBanner = try detailMinimumHeight(model, size: size)

        print("[layout] detail column minimum: \(withoutBanner) with no banner, "
              + "\(withBanner) with the audio banner")
        XCTAssertEqual(withBanner, withoutBanner, accuracy: 0.5,
                       "The audio banner raised the detail column's minimum height from "
                       + "\(withoutBanner) to \(withBanner).")
    }

    private func detailMinimumHeight(_ model: AppModel, size: NSSize) throws -> CGFloat {
        let hosted = host(model, size: size)
        let split = try XCTUnwrap(Self.firstSplitView(in: hosted.host),
                                  "No NSSplitView in the window.")
        let detail = try XCTUnwrap(split.arrangedSubviews.last, "The split view has no detail.")
        return detail.fittingSize.height
    }

    // MARK: The rule

    /// Every pane, both windows.
    private func assertEveryPaneFits(_ model: AppModel,
                                     banner: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        for pane in SidebarPane.allCases {
            model.setSelectedPane(pane)
            for size in Self.windowSizes {
                assertFits(model, label: "\(banner), \(pane.title) pane, \(Int(size.width)) x "
                                         + "\(Int(size.height))",
                           size: size, file: file, line: line)
            }
        }
    }

    /// The window lays its content out inside itself.
    ///
    /// Read off the `NSSplitView` behind the `NavigationSplitView`, because that is the
    /// view that grew: the split view runs from the very top of the window, under the
    /// title bar, down to the top of the bulb strip, and the strip and the footer sit
    /// under it. A split view taller than that pushes the whole root out of both ends of
    /// the window, centered, which is Phil's screenshot: the sidebar's rows, the banner
    /// and the pane header above the top, the strip and the footer below the bottom.
    private func assertFits(_ model: AppModel,
                            label: String,
                            size: NSSize,
                            file: StaticString,
                            line: UInt) {
        let hosted = host(model, size: size)
        guard let split = Self.firstSplitView(in: hosted.host) else {
            return XCTFail("\(label): no NSSplitView in the window.", file: file, line: line)
        }
        let height = hosted.host.bounds.height
        let frame = Self.topDownFrame(of: split, in: hosted.host)
        var room = height - MainWindowMetrics.footerHeight - MainWindowMetrics.dividerHeight
        if model.selectedPane.showsBulbStrip {
            room -= BulbStripMetrics.height + MainWindowMetrics.dividerHeight
        }
        let detailMinimum = split.arrangedSubviews.last?.fittingSize.height ?? .nan
        let numbers = "window \(Int(height)) tall, split view from \(frame.minY) to "
            + "\(frame.maxY) with room for \(room), detail column minimum \(detailMinimum)"
        print("[layout] \(label): \(numbers)")

        XCTAssertEqual(frame.minY, 0, accuracy: 0.5,
                       "\(label): the split view starts off the top of the window. \(numbers)",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, room + 0.5,
                                 "\(label): the split view runs into the strip and the "
                                 + "footer. \(numbers)",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(detailMinimum, room,
                                 "\(label): the detail column asks AppKit for more height "
                                 + "than the window has. \(numbers)",
                                 file: file, line: line)
    }

    // MARK: Hosting

    private struct Hosted {
        var window: NSWindow
        var host: NSView
    }

    /// `MainWindowView` in the kind of window the app's `WindowGroup` makes: titled,
    /// resizable, content running under the title bar. The hosting view adds no Auto
    /// Layout constraints of its own, which is how SwiftUI's own window host behaves, so
    /// the window keeps the size it was given the way Phil's did rather than quietly
    /// growing to fit and hiding the bug.
    private func host(_ model: AppModel, size: NSSize) -> Hosted {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable,
                                          .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        windows.append(window)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        host.layoutSubtreeIfNeeded()
        return Hosted(window: window, host: host)
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }

    /// A view's frame in the host, measured down from the host's top edge whichever way
    /// up the host's own coordinates run.
    private static func topDownFrame(of view: NSView, in host: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: host)
        guard !host.isFlipped else { return rect }
        return CGRect(x: rect.minX, y: host.bounds.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    // MARK: Waiting

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func waitFor(timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !predicate() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
