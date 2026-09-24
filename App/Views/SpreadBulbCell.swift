import Effects
import GoveeLAN
import SwiftUI

/// One bulb in the Bulbs grid: its name, and the band it follows.
///
/// The name is the one the bulb list shows, so the row someone just renamed is the row
/// they recognize here. It gets a line of its own above the control rather than a narrow
/// column beside it, because a name is the only thing on this grid that can be long.
struct SpreadBulbCell: View {

    @Bindable var model: AppModel
    let bulb: Bulb

    /// The name the rest of the app is showing for this bulb. A property rather than a
    /// local in the body so a test can ask the cell what it would draw, and so the grid
    /// renumbers with the list: a bulb nobody has named is called by its place.
    var name: String {
        model.displayName(for: bulb)
    }

    private static let segments: [PartySegment<SpreadGroup>] =
        SpreadGroup.allCases.map { PartySegment(value: $0, title: $0.displayName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(PartyStyle.label)
                .lineLimit(1)
                .truncationMode(.tail)
                // A name too long for its column is still readable on hover rather than
                // being lost to the ellipsis.
                .help(name)
            PartySegmentedPicker(segments: Self.segments,
                                 selection: model.spreadGroup(for: bulb.id),
                                 accessibilityLabel: "\(name), which part of the music it "
                                                     + "follows",
                                 onSelect: select)
        }
        .accessibilityElement(children: .contain)
    }

    private func select(_ group: SpreadGroup) {
        model.setSpreadGroup(group, for: bulb.id)
    }
}
