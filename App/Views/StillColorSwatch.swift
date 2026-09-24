import SwiftUI

/// One color in the Colors pane's grid: the color itself over its name.
///
/// Built the way `PalettePicker`'s chip is, because it is the same idea one size up:
/// choose by looking, not by reading a menu. The differences are what the two are for. A
/// palette chip shows five colors blended along a capsule, so it is a stripe; this is one
/// color, so it is a rectangle big enough to judge, and it is what the room will actually
/// be rather than what it will cycle through.
struct StillColorSwatch: View {

    let color: StillColor
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    /// Big enough to judge a color by and small enough that six fit across the pane.
    /// Wider than it is tall, so a row of them reads as a row of lights rather than as a
    /// grid of tiles.
    static let swatchWidth: CGFloat = 96
    static let swatchHeight: CGFloat = 56
    /// The gap between the swatch and the ring that picks it out.
    ///
    /// Wider than `PartyStyle.chipPadding`, which is what a palette chip uses, and for a
    /// reason worth keeping: the ring is amber and so are six of these swatches. With the
    /// palette's 3 points the ring on Golden hour, Warm or Tangerine sits straight against
    /// a color of its own hue and all but disappears. Six points of the window showing
    /// through is what makes the ring a ring on every color in the catalog.
    static let chipPadding: CGFloat = 6
    /// The smallest a column may be: the swatch plus the padding either side of it. The
    /// grid is adaptive, so this is what decides how many fit.
    static var columnWidth: CGFloat { swatchWidth + chipPadding * 2 }
    /// The chip around the swatch. Concentric: the swatch is `PartyStyle.chipRadius`,
    /// the chip is that plus the padding between them.
    private static var chipRadius: CGFloat { PartyStyle.chipRadius + chipPadding }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                    .fill(ColorConversion.swatch(for: color))
                    .frame(width: Self.swatchWidth, height: Self.swatchHeight)
                    // Every image gets a hairline of its own, so Ice and Moonlight still
                    // have an edge against a pale window.
                    .overlay {
                        RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                            .strokeBorder(.black.opacity(0.14), lineWidth: 1)
                    }
                    .partyShadows(lift)
                Text(color.name)
                    .font(PartyStyle.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(PartyStyle.accent)
                                                : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(Self.chipPadding)
            .background {
                RoundedRectangle(cornerRadius: Self.chipRadius)
                    .fill(isSelected ? AnyShapeStyle(PartyStyle.trough) : AnyShapeStyle(.clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.chipRadius)
                    .strokeBorder(isSelected ? PartyStyle.accent : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.chipRadius))
        }
        .buttonStyle(PartyPressStyle())
        .onHover { isHovering = $0 }
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isHovering)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isSelected)
        .help(help)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The hover lift, which is the same lift the selected chip already carries: hovering
    /// shows you what picking would look like.
    private var lift: PartyStyle.ShadowStack {
        isHovering || isSelected
            ? PartyStyle.liftShadows(colorScheme)
            : PartyStyle.restShadows(colorScheme)
    }

    /// A white says which white it is, because 3000 and 4000 K are a real difference and
    /// two neighboring swatches cannot show it on their own.
    private var help: String {
        switch color.value {
        case .white(let kelvin): return "\(color.name), \(kelvin) K"
        case .rgb: return color.name
        }
    }
}
