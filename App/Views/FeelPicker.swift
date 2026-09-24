import SwiftUI

/// The Feel row: four ready made feels, and the Custom state the sliders fall into.
///
/// It sits directly above Advanced in both windows, which is the whole shape of the
/// control: presets are the easy path, the disclosure under them is the fine tune. Tap a
/// feel and the four sliders move; move a slider and the row says Custom.
struct FeelPicker: View {

    @Bindable var model: AppModel

    /// Custom last, and not selectable: it is a thing the sliders say, not a thing anyone
    /// picks. `nil` is Custom, which is exactly what `matchingPreset` returns for it, so
    /// the row and the settings cannot disagree about which feel is on.
    static let segments: [PartySegment<PartyPreset?>] =
        PartyPreset.allCases.map { PartySegment(value: $0, title: $0.displayName) }
        + [PartySegment(value: nil, title: "Custom", isSelectable: false)]

    /// What Custom means, in the same voice the four summaries are written in.
    static let customSummary = "Your own mix of the four Advanced settings."

    /// Rounded, and the only segmented control in the panel that is. Punchy, Mellow,
    /// Dreamy and Tight are moods; Effect and Bulbs are settings, so they stay in the
    /// same face as every other label.
    static let segmentFont = PartyStyle.presetName

    var body: some View {
        PartySection(title: "Feel", caption: summary) {
            PartySegmentedPicker(segments: Self.segments,
                                 selection: model.settings.matchingPreset,
                                 accessibilityLabel: "Feel, how the lights react",
                                 font: Self.segmentFont,
                                 onSelect: apply)
        }
    }

    private var summary: String {
        model.settings.matchingPreset?.summary ?? Self.customSummary
    }

    /// Custom is not selectable, so the only way in here is one of the four.
    private func apply(_ preset: PartyPreset?) {
        guard let preset else { return }
        model.applyPartyPreset(preset)
    }
}
