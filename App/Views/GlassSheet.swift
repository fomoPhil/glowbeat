import SwiftUI

/// The one glass sheet in the Party panel, which Trigger Level sits on.
///
/// Only one thing in the panel gets this treatment. Glass everywhere is wallpaper; glass
/// on exactly the control that matters is a way of saying which control matters.
///
/// On macOS 26 that is real Liquid Glass, which refracts what is behind it. The
/// deployment target is 14.4, where there is no such thing, so the fallback is a
/// material: still translucent, still lifts off the window, just not refractive.
struct GlassSheet: ViewModifier {

    func body(content: Content) -> some View {
        content
            .padding(PartyStyle.sheetPadding)
            .background { GlassSheetBackground() }
    }
}

/// The sheet itself: the translucent fill, the hairline lit edge, and the layered drop
/// shadow that separates it from the window.
///
/// A view of its own so the shadows land on the sheet rather than on the text standing on
/// it, which is what `.shadow` applied to the whole thing would do.
struct GlassSheetBackground: View {

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PartyStyle.sheetRadius)
    }

    var body: some View {
        fill
            .overlay {
                // The film over the glass, from the mockup's own sheet: blur first, a
                // sliver of white over it. Without it the sheet is only a blurrier patch
                // of the window it is standing on.
                shape.fill(PartyStyle.glassFilm(colorScheme))
            }
            .overlay {
                // A lit top edge rather than a border all the way around: light comes
                // from above, so the bottom of a pane of glass is not brighter than the
                // window behind it.
                shape.strokeBorder(LinearGradient(colors: [PartyStyle.edgeHighlight(colorScheme),
                                                           .clear],
                                                  startPoint: .top,
                                                  endPoint: .bottom),
                                   lineWidth: 1)
            }
            .partyShadows(PartyStyle.sheetShadows(colorScheme))
    }

    @ViewBuilder
    private var fill: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

extension View {

    /// Puts this content on the panel's one glass sheet.
    func glassSheet() -> some View {
        modifier(GlassSheet())
    }
}
