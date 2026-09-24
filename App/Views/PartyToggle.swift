import SwiftUI

/// The Party Mode switch, the transition spinner and the paused row, in one place.
///
/// The window and the menu bar popover both offer this control, and the rules behind it
/// are subtle enough that two copies would drift: a start sits behind the audio
/// permission prompt for as long as the user takes to answer it, the engine only reports
/// `.running` once that returns, and it drops a second start asked for during the first.
struct PartyToggle: View {

    enum Style {
        /// The main window: large switch, the paused row beside it.
        case window
        /// The Party pane's header, where the pane title already says "Party Mode": the
        /// switch alone, with no second copy of the name beside it.
        case paneHeader
        /// The menu bar popover: standard switch, the paused row underneath.
        case popover
    }

    @Bindable var model: AppModel
    var style: Style = .window

    /// What the user last asked the toggle for. Without it the switch would read off
    /// through the whole permission wait, with no way to back out of it.
    @State private var wantsPartyOn = false

    private var isPartyOn: Bool {
        model.partyState != .off
    }

    private var toggleIsOn: Bool {
        isPartyOn || (model.isPartyTransitioning && wantsPartyOn)
    }

    private var pauseReason: String? {
        if case .paused(let reason) = model.partyState { return reason }
        return nil
    }

    /// Turning Party Mode off always lands, mid transition included. Only turning it on
    /// waits, because the engine drops a second start asked for during the first.
    private var canToggleParty: Bool {
        if model.bulbs.isEmpty { return false }
        return !model.isPartyTransitioning || toggleIsOn
    }

    var body: some View {
        content
            .onAppear { wantsPartyOn = isPartyOn }
            .onChange(of: model.partyState) { _, newValue in
                wantsPartyOn = newValue != .off
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .paneHeader:
            HStack(spacing: 10) {
                spinner
                if let pauseReason {
                    Text(pauseReason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    resumeButton
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                toggle
                    .labelsHidden()
            }
            .tint(PartyStyle.accent)
        case .window:
            HStack(spacing: 12) {
                toggle
                    .controlSize(.large)
                spinner
                Spacer(minLength: 0)
                if let pauseReason {
                    HStack(spacing: 10) {
                        Text(pauseReason)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        resumeButton
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            // The panel's one accent, so the switch that starts Party Mode is the same
            // amber as the marker and the chosen segment underneath it. Only in the
            // window: the menu bar popover keeps the system tint it has always had.
            .tint(PartyStyle.accent)
        case .popover:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    toggle
                    spinner
                }
                if let pauseReason {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pauseReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        resumeButton
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var toggle: some View {
        Toggle(isOn: Binding(get: { toggleIsOn },
                             set: { newValue in
                                 wantsPartyOn = newValue
                                 model.setPartyModeEnabled(newValue)
                             })) {
            // Rounded in the window, where it is the panel's title. The menu bar popover
            // keeps the system face along with the system tint it has always had.
            Label("Party Mode", systemImage: "waveform")
                .font(style == .window ? PartyStyle.partyTitle : nil)
        }
        .toggleStyle(.switch)
        .disabled(!canToggleParty)
        .help(model.bulbs.isEmpty
              ? "Party Mode needs at least one bulb."
              : "Match every bulb to whatever your Mac is playing.")
    }

    @ViewBuilder
    private var spinner: some View {
        if model.isPartyTransitioning {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var resumeButton: some View {
        Button("Resume") { model.resumeParty() }
            .disabled(model.isPartyTransitioning)
    }
}
