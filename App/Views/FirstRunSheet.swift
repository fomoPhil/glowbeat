import AppKit
import GoveeLAN
import SwiftUI

/// The first launch walkthrough. Three steps: turn on LAN Control, name the bulbs, done.
///
/// The system audio permission prompt is deliberately not part of first run. It fires the
/// first time Party Mode is switched on, where the user can connect it to what they just
/// asked for.
///
/// Step one uses SF Symbol illustrations rather than Govee Home screenshots. There are no
/// screenshots in the repo and shipping stale ones is worse than none. If real captures
/// arrive later they drop into an asset catalog and replace the symbol in place.
struct FirstRunSheet: View {

    enum Step: Int, CaseIterable, Identifiable {
        case lanControl
        case naming
        case done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .lanControl: return "Turn on LAN Control"
            case .naming: return "Name your bulbs"
            case .done: return "You are set"
            }
        }

        /// The next step, or nil on the last one. Navigation lives on the enum rather
        /// than inside the view body so it can be tested without rendering anything.
        var next: Step? { Step(rawValue: rawValue + 1) }

        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    /// Privacy & Security. There is no working anchor for the Local Network list on
    /// macOS 26.6.2: `SecurityPrivacyExtension` ships anchors for Microphone, Camera and
    /// the rest, but none for Local Network, so both this identifier and the newer
    /// `com.apple.settings.PrivacySecurity.extension` form land on the top of Privacy &
    /// Security. Verified by hand on 26.6.2 (build 25G83). The copy next to the button
    /// therefore tells the user to scroll to Local Network rather than promising the
    /// system will do it for them.
    static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")

    /// The one line about the Schedule pane. Somebody who never opens it should still
    /// know the app can light the room in the morning, and the last step of the guide is
    /// the only place left to say so.
    static let scheduleSentence = "Glowbeat can also light the room at a set time and put "
        + "it out again at night. That lives in the Schedule pane, beside Party Mode and "
        + "Scenes."

    /// How long to wait before treating an empty bulb list as a real result. The app
    /// scans as soon as the window appears, so by the time this elapses the launch scan
    /// has had its chance and "no bulbs" means something rather than "not yet".
    private static let initialScanGrace: Duration = .seconds(3)

    let model: AppModel
    @Binding var isPresented: Bool
    @State private var step: Step
    /// True once a scan has had time to return. Gates the local network help so it does
    /// not accuse macOS of blocking the app half a second after the sheet opens.
    @State private var hasScanned = false

    /// `initialStep` exists so each step can be rendered on its own in a test. The app
    /// always starts at the first step.
    init(model: AppModel, isPresented: Binding<Bool>, initialStep: Step = .lanControl) {
        self.model = model
        self._isPresented = isPresented
        self._step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(Step.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue
                              ? Color.accentColor
                              : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Text(step.title)
                .font(.title2.weight(.semibold))

            Group {
                switch step {
                case .lanControl: lanControlStep
                case .naming: namingStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                if let previous = step.previous {
                    Button("Back") { step = previous }
                }
                Spacer()
                Button(step.next == nil ? "Start using Glowbeat" : "Next") { goForward() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }

    // MARK: Step one

    private var lanControlStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "wifi.router")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Glowbeat talks to your bulbs directly over Wi-Fi. Each bulb has to be told to allow that, once, in the Govee Home app on your phone.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label("Open Govee Home and tap a bulb.", systemImage: "1.circle.fill")
                Label("Tap the settings gear in the top right.", systemImage: "2.circle.fill")
                Label("Turn on LAN Control.", systemImage: "3.circle.fill")
                Label("Repeat for every bulb you want to use.", systemImage: "4.circle.fill")
            }
            .font(.callout)

            HStack(spacing: 12) {
                Button("Scan now") {
                    hasScanned = true
                    model.rescan()
                }
                Text(scanCountLine)
                    .font(.callout)
                    .foregroundStyle(model.bulbs.isEmpty ? .secondary : .primary)
            }

            if hasScanned && model.bulbs.isEmpty {
                localNetworkHelp
            }
        }
        .task {
            // The window starts services and scans on appear, so give that scan its
            // moment before the local network help can claim there is a problem.
            try? await Task.sleep(for: Self.initialScanGrace)
            hasScanned = true
        }
    }

    private var scanCountLine: String {
        switch model.bulbs.count {
        case 0: return "No bulbs found yet."
        case 1: return "Found 1 bulb."
        case let count: return "Found \(count) bulbs."
        }
    }

    private var localNetworkHelp: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS also needs to allow Glowbeat on your local network. Open Privacy & Security, scroll down to Local Network, and turn Glowbeat on.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security") { openLocalNetworkSettings() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openLocalNetworkSettings() {
        guard let url = Self.localNetworkSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Step two

    private var namingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give each bulb a name you will recognize. You can change these any time in the main window.")
                .fixedSize(horizontal: false, vertical: true)

            if model.bulbs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No bulbs yet. Go back a step and scan again.")
                        .foregroundStyle(.secondary)
                    Button("Back to scanning") { step = .lanControl }
                        .controlSize(.small)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        // The same order as the main list, so "Bulb 2" here is the row
                        // numbered 2 there.
                        ForEach(model.orderedBulbs) { bulb in
                            FirstRunNameRow(model: model, bulb: bulb)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: Step three

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Play something, then switch on Party Mode. The first time you do, macOS asks to let Glowbeat listen to your Mac's audio. Say yes, or Party Mode sees silence.")
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.scheduleSentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Glowbeat never turns your bulbs off when it quits. They keep whatever color they were last given.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Navigation

    private func goForward() {
        guard let next = step.next else {
            model.completeFirstRun()
            isPresented = false
            return
        }
        step = next
    }
}

/// One editable bulb name. Commits on Return and on losing focus, which is how the main
/// window's rows behave, so the two do not disagree about what finishing typing means.
private struct FirstRunNameRow: View {

    let model: AppModel
    let bulb: Bulb

    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(bulb.isReachable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .accessibilityLabel(bulb.isReachable ? "Reachable" : "Not reachable")

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }

            Text(bulb.endpoint.host)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .onAppear { reload() }
        .onChange(of: bulb.id) { _, _ in reload() }
    }

    private func reload() {
        guard !isFocused else { return }
        name = model.displayName(for: bulb)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = model.displayName(for: bulb)
            return
        }
        guard trimmed != model.displayName(for: bulb) else { return }
        name = trimmed
        model.setDisplayName(trimmed, for: bulb)
    }
}
