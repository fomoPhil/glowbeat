import XCTest
@testable import Glowbeat

/// Sparkle is wired in for the direct download build, and the test host never starts it.
@MainActor
final class UpdaterTests: XCTestCase {

    func testAnUpdaterBuiltForTheTestHostIsNotStarted() {
        let updater = Updater(start: GlowbeatApp.startsLiveServices(
            environment: ProcessInfo.processInfo.environment))
        XCTAssertFalse(updater.isStarted)
        XCTAssertFalse(updater.canCheckForUpdates,
                       "A stopped updater must not offer a check.")
    }

    func testTheFeedAndKeyAreInTheInfoPlist() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/fomoPhil/glowbeat/releases/latest/download/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "An Ed25519 public key is 32 bytes.")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testTheAudioAndNetworkUsageStringsAreStillThere() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(info["NSAudioCaptureUsageDescription"] as? String)
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"] as? String)
    }
}

final class SupportTests: XCTestCase {

    func testTheDonationLinkIsKoFi() {
        XCTAssertEqual(Support.donationURL.absoluteString, "https://ko-fi.com/philwoolley")
    }
}
