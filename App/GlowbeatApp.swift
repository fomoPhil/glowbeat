import SwiftUI

@main
struct GlowbeatApp: App {

    @State private var model = AppModel.live()

    /// Sparkle. Started on an ordinary launch only, never in the unit test host.
    private let updater = Updater(
        start: GlowbeatApp.startsLiveServices(environment: ProcessInfo.processInfo.environment))

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
}
