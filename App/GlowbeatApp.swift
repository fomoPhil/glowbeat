import AppKit
import os
import SwiftUI

@main
struct GlowbeatApp: App {

    @State private var model: AppModel

    /// Sparkle. Started on an ordinary launch only, never in the unit test host.
    private let updater: Updater

    init() {
        let live = Self.startsLiveServices(environment: ProcessInfo.processInfo.environment)
        // Before the model and Sparkle exist, so a copy that gives way has opened nothing.
        if live {
            Self.giveWayToARunningCopy()
        }
        _model = State(initialValue: AppModel.live())
        updater = Updater(start: live)
    }

    var body: some Scene {
        WindowGroup("Glowbeat") {
            MainWindowView(model: model)
                .onAppear {
                    guard Self.startsLiveServices(environment: ProcessInfo.processInfo.environment) else {
                        return
                    }
                    model.startServices()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.designWidth,
                     height: MainWindowMetrics.defaultHeight)
        .commands {
            AppMenuCommands(updater: updater)
        }

        // Off by default, and `isInserted` means the status item appears and disappears
        // the moment the setting changes, with no relaunch.
        //
        // The binding rides `isMenuBarExtraInserted`, not the stored setting. On a full
        // menu bar macOS evicts the item as fast as it is added and reports that by
        // writing `false` here; answering with `true` again on the next update pass is a
        // loop that never settles, and it hangs the app. Recording the eviction ends it
        // in one write. The stored setting stays on, so Settings still shows what the
        // user asked for and nothing they chose is undone behind their back.
        MenuBarExtra("Glowbeat",
                     image: "MenuBarIcon",
                     isInserted: Self.menuBarInsertionBinding(model: model)) {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    /// A function rather than an inline binding so the rule above can be tested.
    ///
    /// Reading `isMenuBarExtraInserted` rather than `settings` also keeps the `App` body
    /// out of the way of every other setting: `settings` is a single observable property,
    /// so reading one field of it here would re-run this whole scene list on every party
    /// gate drag frame.
    static func menuBarInsertionBinding(model: AppModel) -> Binding<Bool> {
        Binding(get: { model.isMenuBarExtraInserted },
                set: { model.setMenuBarExtraInserted($0) })
    }

    /// Whether this launch opens the LAN socket and starts everything behind it: discovery,
    /// status polling, the network watchers, the light mode and the schedule.
    ///
    /// Always, except when this process is the unit test host. `GlowbeatTests` is hosted by
    /// the real app, so every test run launches this very struct, and until 2026-09-22 each
    /// run bound UDP 4002 and scanned and polled the real bulbs from a second process. A
    /// second process on that port takes bulb replies away from the Glowbeat Phil is
    /// running, and a started schedule or light mode could have painted the real room in
    /// the middle of a run. The tests build their own models on loopback fakes, so the
    /// host has nothing to talk to. Xcode puts `XCTestConfigurationFilePath` in the host's
    /// environment, and `TestHostTests` checks that it still does.
    static func startsLiveServices(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    /// One running copy of Glowbeat, as far as deciding which one stays goes.
    struct RunningCopy: Equatable {
        let pid: pid_t
        let launchDate: Date?
    }

    /// The copy this launch should give way to, if another one is already running.
    ///
    /// `LSMultipleInstancesProhibited` only stops a second launch of the same bundle. Two
    /// copies at different paths, the release in /Applications and a build anywhere else
    /// or a copy still on the mounted disk image, both launch, both bind UDP 4002, and
    /// one quietly takes the bulbs' replies from the other (seen 2026-10-22). The oldest
    /// copy stays. A copy with no launch date counts as the newest, and a tie goes to the
    /// lower pid, so two copies launched together agree and exactly one of them quits.
    static func copyToGiveWayTo(own: RunningCopy, others: [RunningCopy]) -> RunningCopy? {
        func key(_ copy: RunningCopy) -> (Date, pid_t) {
            (copy.launchDate ?? .distantFuture, copy.pid)
        }
        return others
            .filter { $0.pid != own.pid && key($0) < key(own) }
            .min { key($0) < key($1) }
    }

    /// Brings the older copy forward and quits this one.
    private static func giveWayToARunningCopy() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        // A copy on its way out is not one to give way to, or a quick quit and relaunch
        // would leave nothing running.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        let others = running.map { RunningCopy(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let older = copyToGiveWayTo(
                own: RunningCopy(pid: current.processIdentifier, launchDate: current.launchDate),
                others: others),
              let app = running.first(where: { $0.processIdentifier == older.pid }) else { return }
        Logger(subsystem: "com.philwoolley.glowbeat", category: "App")
            .log("Glowbeat is already running as pid \(older.pid, privacy: .public); quitting this copy.")
        app.activate()
        exit(0)
    }
}
