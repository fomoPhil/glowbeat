import Effects
import SwiftUI

/// The Party Mode panel, in the "05 Minimal 2026" look: one neutral surface, one accent,
/// and one glass sheet under the only control anyone turns.
struct PartyPanelView: View {

    /// How the panel arranges itself.
    enum Layout {
        /// One column, top to bottom. The menu bar popover and the Settings window, and
        /// anywhere else narrow.
        case single
        /// Two columns side by side: the sheet, the effect and the palette on the left,
        /// the feel and Advanced on the right.
        ///
        /// The window is a sidebar and a pane now, and a pane is wide and not very tall.
        /// Stacked, the panel with Advanced open is about 820 points tall and the window
        /// it was designed for has about 580 to give it, so one column would put a
        /// scroller under the one panel Phil uses most. Side by side it fits.
        case columns
    }

    @Bindable var model: AppModel
    /// False when the window puts the switch in a header of its own, so the panel does
    /// not show a second copy of it.
    var includesToggle = true
    var layout: Layout = .single

    /// Effects in the order they have always been listed, as segments.
    private var effectSegments: [PartySegment<EffectKind>] {
        EffectKind.allCases.map { PartySegment(value: $0, title: $0.displayName) }
    }

    /// The gap between the two columns. Wider than the gap between two sections in one
    /// of them, so the eye reads two columns rather than one lumpy grid.
    private static let columnSpacing: CGFloat = 24

    var body: some View {
        content
            .padding(PartyStyle.sheetPadding)
            // One accent for the whole panel, so every stock control that draws with the
            // tint lands on the same amber as the marker and the chosen segment.
            .tint(PartyStyle.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .single:
            VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
                if includesToggle {
                    PartyToggle(model: model, style: .window)
                }
                reactionColumn
                settingsColumn
            }
        case .columns:
            VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
                if includesToggle {
                    PartyToggle(model: model, style: .window)
                }
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    reactionColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    settingsColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// What the room reacts to: the level, the effect and the colors.
    @ViewBuilder
    private var reactionColumn: some View {
        VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
            TriggerLevelSheet(model: model)

            PartySection(title: "Effect", caption: model.settings.effectKind.summary) {
                PartySegmentedPicker(segments: effectSegments,
                                     selection: model.settings.effectKind,
                                     accessibilityLabel: "Effect",
                                     onSelect: { model.setEffect($0) })
            }

            // The two controls that belong to one effect, in the same slot: directly
            // under the picker and its summary, appearing and going away with the effect
            // they are for.
            if model.settings.effectKind == .wave {
                travel
            }

            if model.settings.effectKind == .spread {
                SpreadBulbsSection(model: model)
            }

            // The palette stays in this column rather than getting a row of its own
            // under both. Measured both ways: a full width palette leaves this column
            // 130 points shorter than the other one and the pane 87 points taller, which
            // is the opposite of what the pane needs. Ten wrapping chips are what
            // balances the two columns.
            palette
        }
    }

    /// How hard it reacts: the one tap that sets the four, and the four themselves.
    @ViewBuilder
    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
            FeelPicker(model: model)
            advanced
        }
    }

    /// The palette grid, and directly under it the switch that decides how its colors are
    /// laid over the bulbs.
    @ViewBuilder
    private var palette: some View {
        PartySection(title: "Palette") {
            PalettePicker(selection: model.settings.paletteID) { model.setPalette(id: $0) }
            ConfettiToggle(model: model)
        }
    }

    /// Wave is the only effect with a direction, so this is the only control that belongs
    /// to one effect. It sits with the picker rather than in Advanced or in Settings: it
    /// appears when Wave is chosen and goes away again with it, which is what keeps the
    /// panel from growing a slider nobody can use.
    @ViewBuilder
    private var travel: some View {
        PartySection(caption: "How fast the color moves from bulb to bulb. Higher is faster.") {
            LabeledValueSlider(title: "Travel",
                               value: model.settings.waveTravelSpeed,
                               range: WaveEffect.travelRange,
                               snapsTo: 1,
                               accessibilityLabel: "Travel, how fast the wave moves from "
                                                   + "bulb to bulb",
                               format: LabeledValueSlider.bulbsPerSecond,
                               readoutWidth: LabeledValueSlider.travelReadoutWidth,
                               onChange: { model.setWaveTravelSpeed($0, persist: false) },
                               onCommit: { model.setWaveTravelSpeed($0) })
        }
    }

    /// Everything past the two controls that matter.
    ///
    /// Trigger Level is the knob Phil turns and Feel is the one tap that sets the rest;
    /// these four are what either of those is made of. Five sliders in a row read as a
    /// mixing desk, so they fold away and stay however he leaves them. Settings still
    /// shows all four without a disclosure, for anyone who went looking for them there.
    @ViewBuilder
    private var advanced: some View {
        DisclosureGroup(isExpanded: Binding(get: { model.settings.showsPartyAdvanced },
                                            set: { model.setPartyAdvancedExpanded($0) })) {
            PartySliders(model: model)
                .padding(.top, 10)
        } label: {
            Text("Advanced")
                .font(PartyStyle.sectionTitle)
        }
    }
}

/// The checkbox that turns the marker off. One definition for both windows, so the label
/// and the help text cannot drift apart between them.
///
/// It sits with the Trigger Level row rather than behind Advanced: it is the answer to
/// "why is nothing happening", which is the first question someone asks of that row.
struct AlwaysReactsToggle: View {

    @Bindable var model: AppModel
    /// True on the glass sheet, where there is room to say what the box does underneath
    /// it. Settings keeps the one line version, because the whole section explains
    /// itself there.
    var includesCaption = false

    private static let caption = "React to every sound, no matter how quiet."

    var body: some View {
        Toggle(isOn: Binding(get: { model.settings.alwaysReacts },
                             set: { model.setAlwaysReacts($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Always react")
                    .font(PartyStyle.label)
                if includesCaption {
                    Text(Self.caption)
                        .font(PartyStyle.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(PartyCheckboxStyle())
        .help(Self.caption)
    }
}

/// The four sliders behind Advanced, in the order Settings lists them, so someone who
/// learned them in one window finds them laid out the same way in the other.
struct PartySliders: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartySection(caption: "The bulbs move between these two brightnesses: Darkest "
                                  + "between beats, Brightest on a hit.") {
                LabeledValueSlider(title: "Darkest",
                                   value: model.settings.partyFloor,
                                   range: 0...(1 - GlowbeatSettings.minimumBrightnessSpan),
                                   accessibilityLabel: "Darkest brightness",
                                   onChange: { model.setPartyFloor($0, persist: false) },
                                   onCommit: { model.setPartyFloor($0) })
                LabeledValueSlider(title: "Brightest",
                                   value: model.settings.partyCeiling,
                                   accessibilityLabel: "Brightest brightness",
                                   onChange: { model.setPartyCeiling($0, persist: false) },
                                   onCommit: { model.setPartyCeiling($0) })
            }

            PartySection(caption: "Higher is faster. At 100% the lights jump the instant a "
                                  + "hit lands; lower eases them in.") {
                LabeledValueSlider(title: "Snap",
                                   value: model.settings.partySnap,
                                   accessibilityLabel: "Snap, how fast the lights jump on a hit",
                                   format: LabeledValueSlider.snapSeconds,
                                   onChange: { model.setPartySnap($0, persist: false) },
                                   onCommit: { model.setPartySnap($0) })
            }

            PartySection(caption: "How long the lights take to settle after a hit. Higher "
                                  + "is a longer, slower fade.") {
                LabeledValueSlider(title: "Fade",
                                   value: model.settings.partyFade,
                                   accessibilityLabel: "Fade, how slowly the lights settle",
                                   format: LabeledValueSlider.fadeSeconds,
                                   onChange: { model.setPartyFade($0, persist: false) },
                                   onCommit: { model.setPartyFade($0) })
            }

            // Last, because it acts on the four above it: the way back, and what "back"
            // means.
            AdvancedDefaultRow(model: model)
        }
    }
}

/// Palettes are chosen by their colors, so the picker shows the colors rather than
/// hiding ten names in a menu.
///
/// An adaptive grid rather than a row: ten chips do not fit across the window, and a
/// grid wraps them onto a second line instead of squeezing every swatch until the
/// colors stop being readable.
struct PalettePicker: View {

    let selection: String
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Narrow enough that ten chips wrap onto three rows in a pane column rather than
    /// four, and still wide enough for the longest palette name, "Warm white", which
    /// measures 68 points at the caption size.
    private static let columns = [GridItem(.adaptive(minimum: 80), spacing: 8, alignment: .top)]
    private static let swatchHeight: CGFloat = 24

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
            ForEach(Palette.all) { palette in
                Button {
                    onSelect(palette.id)
                } label: {
                    chip(for: palette)
                }
                .buttonStyle(PartyPressStyle())
                .help(palette.name)
                .accessibilityLabel(palette.name)
                .accessibilityAddTraits(palette.id == selection ? [.isSelected] : [])
            }
        }
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: selection)
    }

    private func chip(for palette: Palette) -> some View {
        let isSelected = palette.id == selection
        return VStack(spacing: 6) {
            Capsule()
                .fill(LinearGradient(colors: palette.colors.map { Color(effectsRGB: $0) },
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(height: Self.swatchHeight)
                // Every image gets a hairline of its own, so a pale palette still has an
                // edge against a pale window.
                .overlay { Capsule().strokeBorder(.black.opacity(0.14), lineWidth: 1) }
                .partyShadows(PartyStyle.liftShadows(colorScheme))
            Text(palette.name)
                .font(PartyStyle.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? AnyShapeStyle(PartyStyle.accent)
                                            : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(PartyStyle.chipPadding)
        .background {
            RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                .fill(isSelected ? AnyShapeStyle(PartyStyle.trough) : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                .strokeBorder(isSelected ? PartyStyle.accent : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: PartyStyle.chipRadius))
    }
}

/// One labeled slider with a readout beside it.
///
/// Same live and commit split as the party gate: the value reaches the engine as the
/// slider moves, because setting it against music you are listening to is the whole
/// point, and only the release writes to disk.
///
/// The readout is a percentage by default, which is what a brightness is. Snap and Fade
/// pass their own formatters instead: they set times, and "0.05 s" or "0.5 s" is
/// something a person can picture where "55%" or "46%" is not.
struct LabeledValueSlider: View {

    /// The label column, shared by every slider, so the bars and the readouts line up
    /// straight down the panel. Wide enough for the longest label the app has shown in
    /// this column, which is "Trigger Level".
    static let labelWidth: CGFloat = 88

    /// The readout column. Wide enough for "instant", which measures 56.25 points in SF
    /// Mono at the body size, so the 56 it was while the readouts were SF Pro Text would
    /// now clip it by a quarter of a point.
    static let readoutWidthDefault: CGFloat = 60
    /// Travel's own column. It prints the widest readout in the panel, "10 bulbs/s",
    /// which is 80.36 points in the same face.
    static let travelReadoutWidth: CGFloat = 84

    let title: String
    let value: Double
    /// Darkest stops short of the top, because the two ends may never meet: a slider that
    /// can be dragged somewhere the value cannot go feels broken.
    var range: ClosedRange<Double> = 0...1
    /// Set only by a slider whose value is counted rather than measured. Travel is whole
    /// bulbs a second, and a readout that says 7 while the value is 7.3 is a lie, so that
    /// slider snaps and the others stay continuous.
    ///
    /// Deliberately not `Slider`'s own `step:`. On macOS AppKit draws a row of tick marks
    /// under any slider given one, which Phil asked to be rid of on 2026-09-17, and there
    /// is no way to ask for the stepping without the marks. The slider below is always
    /// continuous and the rounding happens in the binding instead, so the value still
    /// lands on whole units and nothing is drawn under the track.
    var snapsTo: Double?
    let accessibilityLabel: String
    var format: (Double) -> String = LabeledValueSlider.percent
    /// Wide enough for the longest readout the slider prints, measured in the monospaced
    /// face that prints it. The default fits "instant", which is the widest thing the
    /// brightness and timing sliders show.
    var readoutWidth: CGFloat = LabeledValueSlider.readoutWidthDefault
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    /// A 0 through 1 value as a whole percentage.
    static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    /// A Fade value as the settle time it asks for.
    static let fadeSeconds: (Double) -> String = { fade in
        String(format: "%.1f s", EffectTiming.release(forFade: fade))
    }

    /// A Snap value as the rise time it asks for. Anything under `shortestAttack`
    /// completes inside one tick at every supported update rate, so rather than print a
    /// time nobody can see, the top of the slider reads as what it feels like.
    static let snapSeconds: (Double) -> String = { snap in
        let attack = EffectTiming.attack(forSnap: snap)
        guard attack >= EffectTiming.shortestAttack else { return "instant" }
        return String(format: "%.2f s", attack)
    }

    /// A Travel value as the speed it asks for, in whole bulbs a second.
    static let bulbsPerSecond: (Double) -> String = { speed in
        "\(Int(speed.rounded())) bulbs/s"
    }

    /// What the slider hands on: the dragged value held inside the range and, for a
    /// slider that counts rather than measures, rounded to the nearest whole unit.
    ///
    /// The whole of the tick mark fix. `Slider(value:in:step:)` would do the rounding and
    /// draw the marks with it; this does the rounding and the slider stays continuous.
    /// Marks are measured from the bottom of the range rather than from zero, so a range
    /// that starts at 1, like the wake brightness, snaps to 1, 2, 3 and not to 0, 1, 2.
    static func snapped(_ value: Double,
                        snapsTo step: Double?,
                        in range: ClosedRange<Double>) -> Double {
        // A drag cannot produce one, but a hand edited store read back through a binding
        // can, and `min`/`max` would carry it straight through.
        guard value.isFinite else { return range.lowerBound }
        let held = min(range.upperBound, max(range.lowerBound, value))
        // Zero or less would be a division by it. No step is the honest reading.
        guard let step, step > 0 else { return held }
        let marks = ((held - range.lowerBound) / step).rounded()
        return min(range.upperBound, max(range.lowerBound, range.lowerBound + marks * step))
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(PartyStyle.label)
                .frame(width: Self.labelWidth, alignment: .leading)
            slider
                .accessibilityLabel(accessibilityLabel)
            Text(format(value))
                .font(PartyStyle.readout)
                .monospacedDigit()
                .frame(width: readoutWidth, alignment: .trailing)
        }
        // A row is a hit target tall, so two rows of sliders can never have targets that
        // touch.
        .frame(minHeight: PartyStyle.rowHeight)
    }

    /// One continuous slider, whatever the value counts in.
    ///
    /// There used to be two, because `Slider` has no overload taking a step of nil. Now
    /// that the stepping happens in the binding there is nothing to choose between, and
    /// the stepped overload is the one that draws tick marks.
    private var slider: some View {
        let binding = Binding(get: { Self.snapped(value, snapsTo: snapsTo, in: range) },
                              set: { onChange(Self.snapped($0, snapsTo: snapsTo, in: range)) })
        return Slider(value: binding, in: range) { editing in
            guard !editing else { return }
            onCommit(value)
        }
    }
}
