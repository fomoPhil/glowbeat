import SwiftUI

/// The Colors pane: one brightness slider, then four groups of swatches.
///
/// Phil, 2026-09-17: "individual static colors and a brightness slider so you can easily
/// pick a color, choose the brightness, and move on with life." So there is no Apply
/// button and no switch in the pane's header. A click is the whole interaction: it lands
/// on the bulbs at once and then nothing keeps repeating it.
///
/// The brightness sits above the grid rather than under it, which is the one piece of
/// layout worth arguing about. The grid is 26 swatches and does not fit the window, so a
/// slider underneath would be a control you have to scroll past the whole catalog to
/// reach, every time. Above it, it is where the eye already is after a click.
struct ColorsPanelView: View {

    @Bindable var model: AppModel

    /// The one line under the pane's title. Says the thing that makes this pane different
    /// from Party Mode and the scenes: nothing here is running, so it stays.
    static let caption = "Pick a color and it stays until you change it."

    /// Adaptive rather than a fixed count, so the grid fills a wide window and rewraps in
    /// a narrow one instead of squeezing every swatch past the point of being a color.
    private static let columns = [
        GridItem(.adaptive(minimum: StillColorSwatch.columnWidth),
                 spacing: 10,
                 alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
            Text(Self.caption)
                .font(PartyStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            brightness

            Divider()

            ForEach(StillColorGroup.allCases) { group in
                StillColorGroupSection(group: group,
                                       columns: Self.columns,
                                       selection: model.settings.stillColorID,
                                       onSelect: { model.applyStillColor($0) })
            }
        }
        .padding(PartyStyle.sheetPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One accent for the pane, the same amber the rest of the app picks things out
        // with, so the slider's own fill matches the ring on the chosen swatch.
        .tint(PartyStyle.accent)
    }

    /// The same labeled slider the Party panel and the Schedule pane use, so a brightness
    /// set here lines up with every other number in the app and reads in the same
    /// monospaced face.
    private var brightness: some View {
        LabeledValueSlider(title: "Brightness",
                           value: model.settings.stillBrightness,
                           range: StillColor.minimumBrightness...1,
                           accessibilityLabel: "Brightness",
                           onChange: { model.setStillBrightness($0, persist: false) },
                           onCommit: { model.setStillBrightness($0) })
    }
}

/// One group of swatches under its own heading.
///
/// A view of its own rather than a builder inside the pane: four of these are the whole
/// body, and a group is the unit that would move if the catalog ever grew a fifth.
struct StillColorGroupSection: View {

    let group: StillColorGroup
    let columns: [GridItem]
    let selection: String?
    let onSelect: (StillColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PartyStyle.captionSpacing) {
            Text(group.title)
                .font(PartyStyle.sectionTitle)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(StillColor.colors(in: group)) { color in
                    StillColorSwatch(color: color,
                                     isSelected: color.id == selection,
                                     onSelect: { onSelect(color) })
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}
