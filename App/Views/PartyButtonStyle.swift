import SwiftUI

/// The panel's own push button, in the two weights it needs: a quiet one that sits in the
/// trough like an unchosen segment, and a prominent one filled with the amber accent.
///
/// Hand rolled rather than `.bordered` and `.borderedProminent` for the reason
/// `PartySegmentedPicker` is: the stock styles cannot take the accent as a fill, the
/// concentric radii, or the 34 point height that makes a 40 point row. It keeps
/// everything a button owes anyone, including the press scale every other hand rolled
/// control in the panel has and the dimming that says pressing would do nothing.
struct PartyButtonStyle: ButtonStyle {

    enum Weight {
        /// Trough filled. For the button that undoes something.
        case secondary
        /// Amber filled. For the button that keeps something.
        case prominent
    }

    var weight: Weight = .secondary

    /// Enough that the shortest label in the panel, "Reset", still reads as a button
    /// rather than as a chip.
    static let horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration, weight: weight)
    }

    /// A view rather than the style's own body, for the reason `PartyPressStyle` gives:
    /// `@Environment` only tracks changes inside a `View`, so a style reading Reduce
    /// Motion or the enabled state directly would keep whatever they were at launch.
    private struct Pressable: View {

        let configuration: ButtonStyleConfiguration
        let weight: Weight

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .partyButtonFace(weight)
                .opacity(isEnabled ? 1 : PartyStyle.disabledOpacity)
                .scaleEffect(scale)
                .animation(PartyStyle.motion(PartyStyle.press, reduceMotion: reduceMotion),
                           value: configuration.isPressed)
        }

        private var scale: CGFloat {
            guard configuration.isPressed, !reduceMotion else { return 1 }
            return PartyStyle.pressScale
        }
    }
}

/// The face of a party button without the button underneath it.
///
/// It lives apart from the style because the "Saved" confirmation wears the same face and
/// is deliberately not a button: a disabled button would dim the one state it exists to
/// show, which is the same call `PartySegmentedPicker` makes about the Custom segment.
/// One definition, so the two cannot drift into different shapes.
struct PartyButtonFace: ViewModifier {

    let weight: PartyButtonStyle.Weight
    /// True for a face that has to keep the width of the slot it sits in rather than
    /// shrinking to its own label.
    var fillsWidth = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(PartyStyle.label)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, PartyButtonStyle.horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: PartyStyle.segmentHeight)
            .background { fill }
            .contentShape(RoundedRectangle(cornerRadius: PartyStyle.segmentedRadius))
            // A button is a hit target tall, so a row of them cannot end up with targets
            // that touch.
            .frame(minHeight: PartyStyle.rowHeight)
    }

    @ViewBuilder
    private var fill: some View {
        switch weight {
        case .secondary:
            RoundedRectangle(cornerRadius: PartyStyle.segmentedRadius)
                .fill(PartyStyle.trough)
        case .prominent:
            RoundedRectangle(cornerRadius: PartyStyle.segmentedRadius)
                .fill(PartyStyle.accent)
                .partyShadows(PartyStyle.liftShadows(colorScheme))
        }
    }

    /// The quiet weight keeps a full strength label rather than the secondary one an
    /// unchosen segment wears. A segment that is not chosen is a state; a button is an
    /// action, and a half faded label on a button someone can press reads as disabled.
    /// The dimming is what says disabled here, and it is the same 0.35 the marker uses.
    private var foreground: AnyShapeStyle {
        switch weight {
        case .secondary: AnyShapeStyle(.primary)
        case .prominent: AnyShapeStyle(PartyStyle.onAccent(colorScheme))
        }
    }
}

extension View {

    /// The panel's button chrome: the fill, the radius, the 34 point height inside a
    /// 40 point row.
    func partyButtonFace(_ weight: PartyButtonStyle.Weight,
                         fillsWidth: Bool = false) -> some View {
        modifier(PartyButtonFace(weight: weight, fillsWidth: fillsWidth))
    }
}
