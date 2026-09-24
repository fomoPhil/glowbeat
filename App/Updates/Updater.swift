import Sparkle
import SwiftUI

/// Sparkle auto-update for the direct download build.
///
/// The feed (`SUFeedURL`), the EdDSA public key (`SUPublicEDKey`) and automatic checks
/// (`SUEnableAutomaticChecks`) all live in `App/Info.plist`. Releasing a new version is
/// `scripts/release.sh`; the steps are in `docs/releasing.md`.
///
/// The updater is created stopped and only started when `start` is true, which the app
/// ties to `GlowbeatApp.startsLiveServices`. So the unit test host (the real app) never
/// schedules an update check, never touches the network for the feed and never shows an
/// update prompt in the middle of a run.
@MainActor
final class Updater {

    private let controller: SPUStandardUpdaterController

    /// Whether `startUpdater()` ran. Exposed for tests.
    private(set) var isStarted = false

    init(start: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        if start {
            controller.startUpdater()
            isStarted = true
        }
    }

    /// False until the updater has started, and while a check is already running.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" and "Support Glowbeat…" under "About Glowbeat" in the app menu.
struct AppMenuCommands: Commands {

    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") {
                updater.checkForUpdates()
            }
            Button(Support.menuTitle) {
                Support.openDonationPage()
            }
        }
    }
}
