import SwiftUI

/// A card in the 05 look: a faint raised surface with a hairline instead of a border, a
/// heading row along the top, and the concentric radius the rest of the panel uses.
///
/// The Party pane has one glass sheet and everything else flat on the window, because it
/// has one control that matters. The Schedule pane has two groups of controls and neither
/// is the hero, so it uses the mockup's card instead: two surfaces of equal weight side
/// by side, each saying "these settings belong together".
struct PartyCard<Header: View, Content: View>: View {

    let title: String
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    /// The padding inside the card. The radius is this plus the inner radius, so anything
    /// sitting against the card's edge stays concentric with it.
    static var padding: CGFloat { 14 }
    /// 8 + 14, the same rule the glass sheet and the segmented control follow.
    static var radius: CGFloat { PartyStyle.innerRadius + padding }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: PartyStyle.captionSpacing) {
            HStack(spacing: 10) {
                Text(title)
                    .font(PartyStyle.sectionTitle)
                Spacer(minLength: 8)
                header
            }
            .frame(height: 26)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.padding)
        .background {
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.028 : 0.022))
                .partyShadows(PartyStyle.liftShadows(colorScheme))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension PartyCard where Header == EmptyView {

    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, header: { EmptyView() }, content: content)
    }
}
