import Effects
import SwiftUI

/// The Bulbs row: which part of the music each bulb follows in Spread.
///
/// It belongs to one effect, the way Wave's Travel does, so it appears with Spread and
/// goes away again with it and is not in Settings. It sits directly under the effect
/// picker and its summary, which is where Wave's Travel sits, so the panel has one place
/// where "this control belongs to the effect above it" is true.
///
/// A grid rather than a list of rows: six bulbs down one column reads as a spreadsheet,
/// and a name beside a three segment control leaves the name about sixty points to live
/// in. Stacking the name over its own control gives the name the whole cell and fits six
/// bulbs into three rows in the window's normal width. In a narrow window the grid falls
/// back to one column by itself.
struct SpreadBulbsSection: View {

    @Bindable var model: AppModel

    /// Wide enough for a three segment control plus a bulb name above it. Below this the
    /// grid drops to one column rather than squeezing "Bass" until it truncates.
    private static let columns = [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)]

    private static let caption = "Each bulb follows one part of the music: Bass for kicks, "
        + "Mid for vocals and chords, High for hats and sparkle."

    var body: some View {
        // Read once: the order is sorted on every access, and the caption, the branch
        // and the grid all want the same answer.
        let bulbs = model.orderedBulbs
        PartySection(title: "Bulbs", caption: bulbs.isEmpty ? nil : Self.caption) {
            if bulbs.isEmpty {
                Text("No bulbs yet.")
                    .font(PartyStyle.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                    ForEach(bulbs) { bulb in
                        SpreadBulbCell(model: model, bulb: bulb)
                    }
                }
            }
        }
    }
}
