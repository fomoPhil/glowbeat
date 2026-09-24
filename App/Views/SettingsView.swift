import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The Settings window, reached with Command comma or from the menu bar popover.
///
/// Every control writes through `AppModel`, which is the one place that clamps a value,
/// persists it and applies it to the running services. Nothing here keeps its own copy.
struct SettingsView: View {

    @Bindable var model: AppModel

    /// Re read after each change to the login item so the note below the toggle
    /// describes what the system actually did, not what was asked for.
    ///
    /// It starts as `nil`, meaning not asked yet, and is filled in once the window is on
    /// screen. Reading the service's status here instead would be a blocking XPC
    /// round trip to `smd` inside `SettingsView.init`, and `init` runs inside the `App`
    /// body, on every update pass, whether or not this window is open. That is what
    /// turned a busy scene update into a beach ball.
    @State private var loginItemStatus: LoginItemStatus?

    /// The intervals the picker offers, in seconds. Fixed tags: a free slider here would
    /// invite someone to scan every second and flood the network for no benefit.
    static let rescanChoices: [TimeInterval] = [15, 30, 60, 120, 300]

    /// A stored interval that is not one of the choices, from a hand edited plist or a
    /// future build, still has to select a row or the picker renders blank. The nearest
    /// choice is what it shows. Ties go to the shorter interval.
    static func nearestRescanChoice(to seconds: TimeInterval) -> TimeInterval {
        rescanChoices.min { abs($0 - seconds) < abs($1 - seconds) } ?? 60
    }

    /// Spelled out rather than run through a formatter so the rows read the way someone
    /// would say them: seconds under a minute, whole minutes above.
    static func rescanLabel(for seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) seconds" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // MARK: The updates slider

    /// The slider is a ceiling, not the rate: Party Mode shares a fixed budget between the
    /// bulbs (`StreamRateLimiter.roomBudgetPerSecond`), so a big room runs each bulb
    /// slower than this.
    static let updatesTitle = "Most updates per bulb, per second"
    static let updatesCaption = "Glowbeat lowers this automatically when you have many "
        + "bulbs, so the network keeps up."

    /// The number next to the slider: the ceiling on its own when the room can afford it,
    /// and the lower rate the room really gets beside it when it cannot, so the readout
    /// never claims more than the bulbs are sent. "10 (6 with 10 bulbs)".
    static func updatesReadout(ceiling: Int, effective: Int, bulbCount: Int) -> String {
        guard effective < ceiling else { return "\(ceiling)" }
        return "\(ceiling) (\(effective) with \(bulbCount) bulbs)"
    }

    private var rescanSelection: Binding<TimeInterval> {
        Binding(get: { Self.nearestRescanChoice(to: model.settings.rescanInterval) },
                set: { model.setRescanInterval($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                general
                    .tabItem { Label("General", systemImage: "gearshape") }
                ScheduleSettingsTab(model: model)
                    .tabItem { Label("Schedule", systemImage: "clock") }
            }
            SupportFooter()
        }
        .frame(width: Self.width, height: Self.height)
        .task { loginItemStatus = model.loginItemStatus }
        // Approval happens in System Settings, outside this window. Re reading whenever
        // the window comes back to the front is what turns the note below the toggle off
        // once the user has allowed it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginItemStatus = model.loginItemStatus
        }
    }

    /// Wide enough for the Schedule tab's label column, its slider and its readout side by
    /// side, which is the widest row either tab has.
    static let width: CGFloat = 520
    /// Tall enough for the Schedule tab's two cards without a scroller, plus the support
    /// line under the tabs. The General tab is taller than that and scrolls, which is what
    /// a settings form does.
    static let height: CGFloat = 670

    private var general: some View {
        Form {
            Section("General") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Glowbeat in the menu bar",
                           isOn: Binding(get: { model.settings.showsMenuBarExtra },
                                         set: { model.setShowsMenuBarExtra($0) }))
                    Text("If your menu bar is full, macOS may hide the icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open Glowbeat at login",
                           isOn: Binding(get: { model.settings.launchesAtLogin },
                                         set: {
                                             model.setLaunchesAtLogin($0)
                                             loginItemStatus = model.loginItemStatus
                                         }))
                    if let note = loginItemNote {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Login Items") { openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Network") {
                Picker("Look for bulbs every", selection: rescanSelection) {
                    ForEach(Self.rescanChoices, id: \.self) { choice in
                        Text(Self.rescanLabel(for: choice)).tag(choice)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Self.updatesTitle)
                        Spacer(minLength: 8)
                        Text(Self.updatesReadout(ceiling: model.settings.maxUpdatesPerSecond,
                                                 effective: model.effectivePartyUpdatesPerSecond,
                                                 bulbCount: model.reachableBulbs.count))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // Continuous, with the rounding in the setter. A `step:` here is what
                    // makes macOS draw tick marks under the track, and the setter was
                    // already rounding, so the step was only ever buying the marks.
                    Slider(value: Binding(get: { Double(model.settings.maxUpdatesPerSecond) },
                                          set: { model.setMaxUpdatesPerSecond(Int($0.rounded())) }),
                           in: 2...10)
                    Text(Self.updatesCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The Party Mode section carries the panel's accent, so a slider set here
            // and the marker it mirrors in the window are visibly the same control.
            Section("Party Mode") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Trigger Level")
                        Spacer(minLength: 8)
                        Text("\(Int((model.settings.partyGate * 100).rounded()))%")
                            .font(PartyStyle.readout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .opacity(model.settings.alwaysReacts
                                     ? LevelMeter.disabledOpacity : 1)
                    }
                    Slider(value: Binding(get: { model.settings.partyGate },
                                          set: { model.setPartyGate($0, persist: false) }),
                           in: 0...1) { editing in
                        // The gate reaches the engine as the slider moves, so the room
                        // responds, but the store is only written when the drag ends.
                        guard !editing else { return }
                        model.setPartyGate(model.settings.partyGate)
                    }
                        .accessibilityLabel("Trigger Level")
                        // Always react ignores this value, so the slider goes with the
                        // marker it mirrors rather than staying live and doing nothing.
                        .disabled(model.settings.alwaysReacts)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AlwaysReactsToggle(model: model)
                    }
                    Text("Lights kick in when the music is louder than the marker. "
                         + "Lower catches more, higher only the loud parts. This is the "
                         + "same marker that sits on the bar in the Party Mode panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The same four values as one tap, above the four sliders they set, so
                // the easy path comes first here the way it does in the window.
                FeelPicker(model: model)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueSlider(title: "Darkest",
                                       value: model.settings.partyFloor,
                                       range: 0...(1 - GlowbeatSettings.minimumBrightnessSpan),
                                       accessibilityLabel: "Darkest brightness",
                                       onChange: { model.setPartyFloor($0, persist: false) },
                                       onCommit: { model.setPartyFloor($0) })
                    LabeledValueSlider(title: "Brightest",
                                       value: model.settings.partyCeiling,
                                       accessibilityLabel: "Brightest brightness",
                                       onChange: { model.setPartyCeiling($0, persist: false) },
                                       onCommit: { model.setPartyCeiling($0) })
                    Text("The range Party Mode works in: the bulbs sit at Darkest between "
                         + "beats and reach Brightest on a hit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledValueSlider(title: "Snap",
                                       value: model.settings.partySnap,
                                       accessibilityLabel: "Snap, how fast the lights jump on a hit",
                                       format: LabeledValueSlider.snapSeconds,
                                       onChange: { model.setPartySnap($0, persist: false) },
                                       onCommit: { model.setPartySnap($0) })
                    Text("Higher is faster. At 100% the lights jump the instant a hit "
                         + "lands; lower eases them in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledValueSlider(title: "Fade",
                                       value: model.settings.partyFade,
                                       accessibilityLabel: "Fade, how slowly the lights settle",
                                       format: LabeledValueSlider.fadeSeconds,
                                       onChange: { model.setPartyFade($0, persist: false) },
                                       onCommit: { model.setPartyFade($0) })
                    Text("How long the lights take to settle after a hit. Higher is a "
                         + "longer, slower fade.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The same row the Party panel puts at the end of Advanced, because
                    // this window shows the same four sliders: someone who set them here
                    // has to be able to get back from here too.
                    AdvancedDefaultRow(model: model)
                }
            }
            .tint(PartyStyle.accent)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// macOS can accept the registration and still hold it for approval, and it can turn
    /// a login item off behind the app's back. Either way the user is told, rather than
    /// left with a switch that looks on and does nothing.
    private var loginItemNote: String? {
        Self.loginItemNote(launchesAtLogin: model.settings.launchesAtLogin,
                           status: loginItemStatus)
    }

    /// Pure, so the rules can be read and tested without a service to ask.
    /// A `nil` status is "not read yet" and says nothing rather than guessing wrong.
    static func loginItemNote(launchesAtLogin: Bool, status: LoginItemStatus?) -> String? {
        guard launchesAtLogin, let status else { return nil }
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "macOS is waiting for you to allow Glowbeat under Login Items."
        default:
            return "macOS has not turned this on. Check Glowbeat under Login Items."
        }
    }

    private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
