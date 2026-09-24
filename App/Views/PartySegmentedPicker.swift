import SwiftUI

/// The panel's segmented control: a recessed bed with one raised, amber segment in it.
///
/// Hand rolled rather than `.pickerStyle(.segmented)` because the stock control cannot
/// carry the three things the look is made of: the accent on the chosen segment, the
/// concentric radii (11 outside, 8 inside, 3 of padding between), and a 40 point row.
/// Everything a picker owes anyone is still here: one accessibility element, a selected
/// trait on the chosen segment, and a label on the group.
struct PartySegmentedPicker<Value: Hashable>: View {

    let segments: [PartySegment<Value>]
    let selection: Value
    let accessibilityLabel: String
    /// The face the segment titles are drawn in. Text by default, because a segment is
    /// normally a setting. Only the Feel row passes anything else: its segments are
    /// moods, so they are drawn rounded.
    var font: Font = PartyStyle.label
    let onSelect: (Value) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                if segment.isSelectable {
                    Button {
                        onSelect(segment.value)
                    } label: {
                        label(for: segment)
                    }
                    .buttonStyle(PartyPressStyle())
                    .accessibilityAddTraits(segment.value == selection ? [.isSelected] : [])
                } else {
                    // Not a button: a segment nobody can press should not look pressable,
                    // and a disabled button would dim the one state it exists to show.
                    label(for: segment)
                        .accessibilityAddTraits(segment.value == selection ? [.isSelected] : [])
                }
            }
        }
        .padding(PartyStyle.segmentPadding)
        .background {
            RoundedRectangle(cornerRadius: PartyStyle.segmentedRadius)
                .fill(PartyStyle.trough)
        }
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func label(for segment: PartySegment<Value>) -> some View {
        let isSelected = segment.value == selection
        return Text(segment.title)
            .font(font)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? AnyShapeStyle(PartyStyle.accent)
                                        : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: PartyStyle.segmentHeight)
            .background { background(isSelected: isSelected) }
            .contentShape(RoundedRectangle(cornerRadius: PartyStyle.innerRadius))
    }

    @ViewBuilder
    private func background(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: PartyStyle.innerRadius)
                .fill(PartyStyle.raised)
                .partyShadows(PartyStyle.liftShadows(colorScheme))
        }
    }
}
