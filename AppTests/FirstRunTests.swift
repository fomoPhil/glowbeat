import GoveeLAN
import SwiftUI
import XCTest
@testable import Glowbeat

/// Covers the first run flag, the step machine behind the sheet and the one system URL
/// the sheet opens. The view itself is a value type, so what is worth testing is the
/// model API it drives plus the fact that every step's body evaluates.
@MainActor
final class FirstRunTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""

    private let configuration = LANConfiguration(replyPort: 0,
                                                 commandPort: .matchingReplySource,
                                                 joinsMulticast: false,
                                                 extraScanTargets: [])

    /// Every model gets its own defaults suite. Nothing here reads or writes
    /// `UserDefaults.standard`, so a test run cannot change the real app's settings.
    private func makeModel() throws -> AppModel {
        if socket == nil {
            socket = LANSocket(configuration: configuration)
            try socket.start()
        }
        if suiteName.isEmpty {
            suiteName = "glowbeat.tests.\(UUID().uuidString)"
        }
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
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: The flag

    func testAFreshInstallHasNotCompletedFirstRun() throws {
        let model = try makeModel()
        XCTAssertFalse(model.settings.hasCompletedFirstRun)
    }

    func testCompletingFirstRunSticks() throws {
        let model = try makeModel()
        model.completeFirstRun()
        XCTAssertTrue(model.settings.hasCompletedFirstRun)
    }

    /// The point of the flag is that the sheet does not come back on the next launch, so
    /// it has to survive a new model reading the same store, not just the live object.
    func testCompletingFirstRunSurvivesANewModelOnTheSameStore() throws {
        let first = try makeModel()
        XCTAssertFalse(first.settings.hasCompletedFirstRun)
        first.completeFirstRun()

        let second = try makeModel()
        XCTAssertTrue(second.settings.hasCompletedFirstRun)
    }

    // MARK: The step machine

    func testTheSheetHasExactlyThreeSteps() {
        XCTAssertEqual(FirstRunSheet.Step.allCases.count, 3)
        XCTAssertEqual(FirstRunSheet.Step.allCases.first, .lanControl)
        XCTAssertEqual(FirstRunSheet.Step.allCases.last, .done)
    }

    func testTheStepsRunForwardAndBackInOrderAndStopAtBothEnds() {
        XCTAssertEqual(FirstRunSheet.Step.lanControl.next, .naming)
        XCTAssertEqual(FirstRunSheet.Step.naming.next, .done)
        XCTAssertNil(FirstRunSheet.Step.done.next)

        XCTAssertNil(FirstRunSheet.Step.lanControl.previous)
        XCTAssertEqual(FirstRunSheet.Step.naming.previous, .lanControl)
        XCTAssertEqual(FirstRunSheet.Step.done.previous, .naming)
    }

    func testEveryStepHasATitle() {
        for step in FirstRunSheet.Step.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step) has no title")
            // House style: no em dashes anywhere in user facing copy.
            XCTAssertFalse(step.title.contains("\u{2014}"), "\(step) title has an em dash")
        }
    }

    // MARK: The local network button

    /// Ruling for this task: step one has to point at the macOS local network permission,
    /// because macOS blocks the app there with no visible prompt. The URL has to parse or
    /// the button silently does nothing.
    func testTheLocalNetworkSettingsURLIsTheSystemPrivacyPane() throws {
        let url = try XCTUnwrap(FirstRunSheet.localNetworkSettingsURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    // MARK: Rendering

    /// A sheet is never on screen during a build, so without this a crash in any step's
    /// body would first show up in front of the user.
    func testEveryStepBodyRenders() throws {
        let model = try makeModel()
        for step in FirstRunSheet.Step.allCases {
            let sheet = FirstRunSheet(model: model,
                                      isPresented: .constant(true),
                                      initialStep: step)
            let renderer = ImageRenderer(content: sheet)
            XCTAssertNotNil(renderer.nsImage, "\(step) did not render")
        }
    }

    func testTheSheetHoldsTheModelItWasGiven() throws {
        let model = try makeModel()
        let sheet = FirstRunSheet(model: model, isPresented: .constant(true))
        XCTAssertTrue(sheet.model === model)
    }

    /// The window is what puts the sheet on screen, so it has to compile and render with
    /// the state that decides whether the sheet opens.
    func testTheMainWindowRendersWithTheFirstRunSheetAttached() throws {
        let model = try makeModel()
        let renderer = ImageRenderer(content: MainWindowView(model: model)
            .frame(width: 780, height: 520))
        XCTAssertNotNil(renderer.nsImage)
    }
}
