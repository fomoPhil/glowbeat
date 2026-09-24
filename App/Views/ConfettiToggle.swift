import SwiftUI

/// The Confetti switch. One definition for the Party panel and the menu bar popover, so
/// the label and the help text cannot drift apart between them.
///
/// It sits directly under the palette because it is about the palette: which of its
/// colors each bulb wears. It works with every effect, so unlike Travel or the Spread
/// bands it never comes and goes with the effect picker.
struct ConfettiToggle: View {

    enum Style {
        /// The Party panel: a row with the label, the caption under it, and the switch at
        /// the far end, in the panel's own type and accent.
        case panel
        /// The menu bar popover: a standard switch row, the caption as its tooltip.
        case popover
    }

    @Bindable var model: AppModel
    var style: Style = .panel

    static let title = "Confetti"
    static let caption = "Every bulb gets its own color from the palette, and never matches "
        + "its neighbors."

    private var isOn: Binding<Bool> {
        Binding(get: { model.settings.partyConfetti },
                set: { model.setPartyConfetti($0) })
    }

    var body: some View {
        switch style {
        case .panel:
            // One toggle whose label fills the row, so the switch sits at the far end and
            // VoiceOver reads one control with one name rather than a row of pieces.
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title)
                        .font(PartyStyle.label)
                    Text(Self.caption)
                        .font(PartyStyle.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .tint(PartyStyle.accent)
            .frame(minHeight: PartyStyle.rowHeight)
            .accessibilityLabel(Self.title)
            .accessibilityHint(Self.caption)
            .help(Self.caption)
        case .popover:
            Toggle(Self.title, isOn: isOn)
                .toggleStyle(.switch)
                .help(Self.caption)
        }
    }
}
