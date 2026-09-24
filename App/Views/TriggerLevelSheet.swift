import SwiftUI

/// Trigger Level, on the panel's one glass sheet.
///
/// It is the knob Phil actually turns, so it gets the sheet, the big readout and the top
/// of the panel, and everything else in Party Mode sits flat on the window underneath it.
struct TriggerLevelSheet: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Trigger Level")
                    .font(PartyStyle.heroTitle)
                Spacer(minLength: 8)
                Text(percentText)
                    .font(PartyStyle.heroValue)
                    .monospacedDigit()
                    .opacity(model.settings.alwaysReacts ? LevelMeter.disabledOpacity : 1)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 16)

            LevelMeter(level: model.level,
                       gate: model.settings.partyGate,
                       isGateEnabled: !model.settings.alwaysReacts,
                       onGateChange: { model.setPartyGate($0, persist: false) },
                       onGateCommit: { model.setPartyGate($0) })

            Text("Lights kick in when the music is louder than the marker. Lower "
                 + "catches more, higher only the loud parts.")
                .font(PartyStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            AlwaysReactsToggle(model: model, includesCaption: true)
                .padding(.top, 4)
        }
        .glassSheet()
    }

    /// The same form the marker's own label uses, so the big number and the tooltip can
    /// never disagree.
    private var percentText: String {
        "\(Int((model.settings.partyGate * 100).rounded()))%"
    }
}
