import SwiftUI

/// The Colors block in the menu bar popover: the whole catalog as four rows of small
/// swatches, between the All bulbs block and Party Mode.
///
/// Phil, 2026-09-17: "add the color selection to the toolbar. Maybe just have colors and
/// then a simple swatch color picker thing that has the different colors that you have
/// here in the app."
///
/// The same 26 colors as the pane and the same one shot behind them: this reads
/// `StillColor.colors(in:)` and calls `AppModel.applyStillColor`, so there is exactly one
/// catalog and exactly one apply path in the app. What is different here is only the
/// size. There is no room for a name under a swatch in a popover, so the name lives in
/// the tooltip and in the accessibility label, and the applied color is written once,
/// beside the header, where the eye already is.
struct MenuBarColorsSection: View {

    let model: AppModel

    // MARK: Metrics
    //
    // Four rows, one per catalog group, so the whites cluster at the top exactly the way
    // they do in the pane and nothing has to be labeled. The widest row is Mood's nine,
    // and that row is what sets every number below: nine cells and the eight gaps between
    // them have to fit inside the popover with its padding taken off.

    /// The colored rectangle itself. Small enough that nine fit across a popover, big
    /// enough to still read as a color rather than as a dot.
    static let swatchWidth: CGFloat = 26
    static let swatchHeight: CGFloat = 18
    static let swatchRadius: CGFloat = 6

    /// The cell around it, which is also the hit area.
    ///
    /// The app's usual floor is `PartyStyle.hitTarget`, 40 points, and that is simply not
    /// possible for 26 swatches in a 320 point window: nine 40 point targets are 360
    /// points before a single gap. 28 by 24 is the floor this grid holds instead, with
    /// real clear space on every side of it, so no two targets touch and a click near an
    /// edge cannot land on the neighbor.
    static let cellWidth: CGFloat = 28
    static let cellHeight: CGFloat = 24
    /// Between cells along a row.
    static let spacing: CGFloat = 4
    /// And between rows, which is not the same number.
    ///
    /// The hit area is 2 points taller than the swatch on each side and 1 point wider on
    /// each side, so an equal spacing would draw a 10 point gap between rows against a 6
    /// point gap along one. Optically even beats numerically even: 2 here puts the two
    /// gaps within 2 points of each other, and the rows still cannot touch.
    static let rowSpacing: CGFloat = 2

    /// The ring around the chosen swatch, drawn at the cell's edge.
    ///
    /// Concentric: the swatch's radius plus the one point of window showing between the
    /// swatch and the ring. That gap is thin, which is the whole reason the chosen swatch
    /// also pulls in slightly and the ring is 2 points thick. Six of these colors are
    /// amber and so is the ring, and the colors report's own lesson from the big pane is
    /// that an amber ring lying straight against an amber swatch disappears.
    static let ringRadius: CGFloat = 7
    static let ringWidth: CGFloat = 2
    /// What the chosen swatch shrinks to, so there is real background between it and its
    /// ring on every color in the catalog. The frame does not move, so nothing reflows.
    static let selectedScale: CGFloat = 0.9

    /// The rows, which are the catalog's own groups in the catalog's own order.
    static let rows: [StillColorGroup] = StillColorGroup.allCases

    /// The longest row, which is what the grid has to be wide enough for.
    static var widestRow: Int {
        rows.map { StillColor.colors(in: $0).count }.max() ?? 0
    }

    static var gridWidth: CGFloat {
        let count = CGFloat(widestRow)
        return count * cellWidth + max(0, count - 1) * spacing
    }

    static var gridHeight: CGFloat {
        let count = CGFloat(rows.count)
        return count * cellHeight + max(0, count - 1) * rowSpacing
    }

    /// What the room is wearing, beside the header.
    ///
    /// The live half rather than the remembered one, and the same word the sidebar uses:
    /// a relaunch rings the swatch someone chose but cannot claim the bulbs are still on
    /// it, so this says "Off" until something in this run put a color there.
    static func readout(applied: StillColor?) -> String {
        applied?.name ?? "Off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Colors")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(Self.readout(applied: model.appliedStillColor))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(Self.rows) { group in
                    HStack(spacing: Self.spacing) {
                        ForEach(StillColor.colors(in: group)) { color in
                            MenuBarColorSwatch(color: color,
                                               isSelected: color.id == model.settings.stillColorID,
                                               onSelect: { model.applyStillColor(color) })
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(group.title)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Colors")
        }
    }
}

/// One swatch in the popover's grid: the color, and a ring when it is the chosen one.
///
/// `StillColorSwatch` one quarter the size and without its name. Kept as its own view
/// rather than as a mode of that one, because at this size every decision is different:
/// there is no label, the hit area is larger than the thing drawn, and the ring has to
/// survive sitting one point from a color of its own hue.
struct MenuBarColorSwatch: View {

    let color: StillColor
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    /// What the swatch is painted with: the pane's own conversion, so a white is drawn in
    /// the white it really is and the two grids cannot disagree about a color.
    static func fill(for color: StillColor) -> Color {
        ColorConversion.swatch(for: color)
    }

    /// The tooltip, which is the only place the name is written at this size. A white
    /// carries its temperature, because 3000 and 4000 are a real difference that two
    /// 26 point rectangles cannot show on their own.
    static func help(for color: StillColor) -> String {
        switch color.value {
        case .white(let temperature): return "\(color.name), \(temperature) K"
        case .rgb: return color.name
        }
    }

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: MenuBarColorsSection.swatchRadius)
                .fill(Self.fill(for: color))
                // A hairline of its own, so Ice and Moonlight still have an edge against
                // a pale popover and the amber ring never lies straight on an amber fill.
                .overlay {
                    RoundedRectangle(cornerRadius: MenuBarColorsSection.swatchRadius)
                        .strokeBorder(.black.opacity(0.2), lineWidth: 1)
                }
                .frame(width: MenuBarColorsSection.swatchWidth,
                       height: MenuBarColorsSection.swatchHeight)
                .scaleEffect(isSelected ? MenuBarColorsSection.selectedScale : 1)
                .partyShadows(lift)
                .frame(width: MenuBarColorsSection.cellWidth,
                       height: MenuBarColorsSection.cellHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: MenuBarColorsSection.ringRadius)
                        .strokeBorder(PartyStyle.accent.opacity(isSelected ? 1 : 0),
                                      lineWidth: MenuBarColorsSection.ringWidth)
                }
                .contentShape(RoundedRectangle(cornerRadius: MenuBarColorsSection.ringRadius))
        }
        .buttonStyle(PartyPressStyle())
        .onHover { isHovering = $0 }
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isHovering)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isSelected)
        .help(Self.help(for: color))
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The same hover lift the big swatch carries, so hovering shows what picking would
    /// look like. At this size it is most of what tells a pointer it is over a target.
    private var lift: PartyStyle.ShadowStack {
        isHovering || isSelected
            ? PartyStyle.liftShadows(colorScheme)
            : PartyStyle.restShadows(colorScheme)
    }
}
