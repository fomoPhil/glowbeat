import AppKit
import XCTest
import GoveeLAN
@testable import Glowbeat

/// The unit test host is the real Glowbeat app, so every app test run launches
/// `GlowbeatApp` itself, with `AppModel.live()` behind its window.
///
/// Until 2026-09-22 that window's `onAppear` started the live services: it bound UDP
/// 4002, scanned and polled the real bulbs, and started the schedule and the light mode
/// against the real room. The handoff's hard-won facts say what a second process on 4002
/// does: it takes bulb replies away from the Glowbeat Phil is running. The suite never
/// needed any of it; every test that wants a model builds its own on loopback fakes.
@MainActor
final class TestHostTests: XCTestCase {

    /// The shipping app still does everything it always did.
    func testAnOrdinaryLaunchStartsTheLiveServices() {
        XCTAssertTrue(GlowbeatApp.startsLiveServices(environment: [:]))
        XCTAssertTrue(GlowbeatApp.startsLiveServices(environment: [
            "HOME": "/Users/someone",
            "PATH": "/usr/bin:/bin",
        ]))
    }

    func testALaunchAsTheTestHostStartsNone() {
        XCTAssertFalse(GlowbeatApp.startsLiveServices(environment: [
            "XCTestConfigurationFilePath": "/tmp/GlowbeatTests.xctestconfiguration",
        ]))
    }

    // MARK: One copy at a time, whatever path it runs from

    /// The release in /Applications and a build anywhere else are the same bundle at two
    /// paths, and both launch. The newer one gives way to the older one.
    func testANewerCopyGivesWayToTheOlderOne() {
        let older = GlowbeatApp.RunningCopy(pid: 900, launchDate: Date(timeIntervalSince1970: 100))
        let newer = GlowbeatApp.RunningCopy(pid: 500, launchDate: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(GlowbeatApp.copyToGiveWayTo(own: newer, others: [older, newer]), older)
        XCTAssertNil(GlowbeatApp.copyToGiveWayTo(own: older, others: [older, newer]),
                     "The older copy quit too, so nothing is left running.")
    }

    /// Two copies launched in the same instant must agree, or both quit.
    func testTwoCopiesLaunchedTogetherKeepExactlyOne() {
        let date = Date(timeIntervalSince1970: 100)
        let first = GlowbeatApp.RunningCopy(pid: 10, launchDate: date)
        let second = GlowbeatApp.RunningCopy(pid: 11, launchDate: date)
        XCTAssertNil(GlowbeatApp.copyToGiveWayTo(own: first, others: [first, second]))
        XCTAssertEqual(GlowbeatApp.copyToGiveWayTo(own: second, others: [first, second]), first)
    }

    /// A copy run straight from its binary has no launch date, and counts as the newest.
    func testACopyWithNoLaunchDateGivesWay() {
        let dated = GlowbeatApp.RunningCopy(pid: 900, launchDate: Date(timeIntervalSince1970: 100))
        let undated = GlowbeatApp.RunningCopy(pid: 10, launchDate: nil)
        XCTAssertEqual(GlowbeatApp.copyToGiveWayTo(own: undated, others: [dated, undated]), dated)
        XCTAssertNil(GlowbeatApp.copyToGiveWayTo(own: dated, others: [dated, undated]))
    }

    func testAloneThereIsNothingToGiveWayTo() {
        let only = GlowbeatApp.RunningCopy(pid: 10, launchDate: Date())
        XCTAssertNil(GlowbeatApp.copyToGiveWayTo(own: only, others: [only]))
        XCTAssertNil(GlowbeatApp.copyToGiveWayTo(own: only, others: []))
    }

    /// Xcode tells the host what it is through its environment. If a future Xcode stops,
    /// this is the test that says so, rather than the next run quietly binding the bulb
    /// port again.
    func testThisProcessIsRecognizedAsTheTestHost() {
        let keys = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("XCTest") }
        print("[testhost] XCTest keys in this process: \(keys.sorted())")
        XCTAssertFalse(GlowbeatApp.startsLiveServices(environment: ProcessInfo.processInfo.environment))
    }

    /// The outcome itself: nothing in this process holds the port the bulbs reply to.
    ///
    /// Waits for the app's own window first, because its `onAppear` is where the services
    /// were started, and a check made before it ran would prove nothing.
    func testTheTestHostNeverBindsTheBulbPort() async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Self.appWindowIsOnScreen() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(Self.appWindowIsOnScreen(),
                      "The app's own window never appeared, so this check would prove nothing. "
                      + "Windows: \(NSApp.windows.map(\.title))")
        // A few turns of the run loop after it appeared, for the `onAppear` behind it.
        try await Task.sleep(nanoseconds: 300_000_000)

        let bulbPort = LANConfiguration.production.replyPort
        let ports = OpenUDPPorts.inThisProcess()
        print("[testhost] UDP ports bound in this process: \(ports.sorted())")
        XCTAssertFalse(ports.contains(bulbPort),
                       "The test host bound UDP \(bulbPort), the port the real bulbs reply to.")
    }

    /// The check above is only worth something if it can see a bound port at all.
    func testThePortCheckSeesASocketThisProcessHolds() throws {
        let blocker = try XCTUnwrap(BlockedPort(), "Could not bind a port to look for.")
        defer { blocker.close() }
        XCTAssertTrue(OpenUDPPorts.inThisProcess().contains(blocker.port),
                      "The check missed UDP \(blocker.port), which this test holds.")
    }

    private static func appWindowIsOnScreen() -> Bool {
        NSApp.windows.contains { $0.title == "Glowbeat" && $0.isVisible }
    }
}
