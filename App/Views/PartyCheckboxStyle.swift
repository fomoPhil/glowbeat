import SwiftUI

/// The Party panel's checkbox: a rounded box that fills with the accent when it is on,
/// with the whole row as its hit area.
///
/// A style of its own rather than `.checkbox` for two reasons the mockup asks for and
/// AppKit will not give: the accent has to be the panel's amber rather than the system
/// highlight, and the target has to be at least `PartyStyle.hitTarget` tall. A stock
/// checkbox is 14 points of box with a hit region to match.
struct PartyCheckboxStyle: ToggleStyle {

    func makeBody(configuration: Configuration) -> some View {
        Box(configuration: configuration)
    }

    private struct Box: View {

        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// The drawn box. The row around it is what gets pressed.
        private static let side: CGFloat = 17
        private static let radius: CGFloat = 5

        var body: some View {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    box
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: PartyStyle.hitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PartyPressStyle())
            // Without this the row reads to VoiceOver as a button rather than as a
            // checkbox that is on or off.
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private var box: some View {
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(configuration.isOn ? AnyShapeStyle(PartyStyle.accent)
                                         : AnyShapeStyle(PartyStyle.trough))
                .frame(width: Self.side, height: Self.side)
                .overlay { check }
                .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                           value: configuration.isOn)
                // Boxes sit on a baseline with the label beside them, not on the text's
                // own baseline, which would drop them by the descender.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        }

        /// Scale, opacity and blur rather than an appearance out of nothing, so the tick
        /// arrives rather than blinking on.
        private var check: some View {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(configuration.isOn ? 1 : 0.25)
                .opacity(configuration.isOn ? 1 : 0)
                .blur(radius: configuration.isOn ? 0 : 4)
        }

        private func toggle() {
            configuration.isOn.toggle()
        }
    }
}
