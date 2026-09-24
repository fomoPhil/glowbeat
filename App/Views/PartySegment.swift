import Foundation

/// One option on a `PartySegmentedPicker`.
struct PartySegment<Value: Hashable>: Identifiable {

    let value: Value
    let title: String
    /// False for a state the row can show but nobody can choose. "Custom" on the Feel row
    /// is the only one: it is what the four Advanced sliders say when they are not on a
    /// preset, so it arrives by itself when a slider moves and is left by picking a feel.
    var isSelectable = true

    var id: Value { value }
}
