import Effects
import SwiftUI

/// The Scenes section: the non-music modes, between the bulb list and Party Mode.
///
/// Party Mode's switch is a large one because it is the app's headline. This is the same
/// control at standard size, because a scene is the quieter thing you leave running.
struct ScenesPanelView: View {

    enum Style {
        /// The main window: picker, switch, speed and, for Sunset, a progress bar.
        case window
        /// The menu bar popover: switch and picker only.
        case popover
    }

    @Bindable var model: AppModel
    var style: Style = .window
    /// False when the window puts the switch in a section header of its own, so the panel
    /// does not show a second copy of it.
    var includesToggle = true

    private var isRunning: Bool {
        model.isSceneRunning
    }

    /// Scenes stream colors at bulbs, so they need a bulb that can be reached, not just
    /// one that has been seen.
    private var hasReachableBulbs: Bool {
        model.bulbs.contains(where: \.isReachable)
    }

    private var kind: SceneKind {
        model.settings.sceneKind
    }

    var body: some View {
        switch style {
        case .window: window
        case .popover: popover
        }
    }

    private var look: SceneLook {
        model.sceneLook
    }

    /// Between the two columns, the same gap the Party pane uses.
    private static let columnSpacing: CGFloat = 24

    private static let kindSegments: [PartySegment<SceneKind>] =
        SceneKind.allCases.map { PartySegment(value: $0, title: $0.displayName) }

    private var window: some View {
        VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
            if includesToggle || model.sceneProgress != nil {
                HStack(spacing: 12) {
                    if includesToggle {
                        sceneToggle
                            .font(.headline)
                    }
                    Spacer(minLength: 8)
                    if let progress = model.sceneProgress {
                        SceneProgressView(progress: progress)
                            .frame(width: 180)
                    }
                }
            }

            PartySection(caption: Self.summary(for: kind)) {
                PartySegmentedPicker(segments: Self.kindSegments,
                                     selection: kind,
                                     accessibilityLabel: "Scene",
                                     onSelect: { model.setScene(kind: $0) })
            }

            HStack(alignment: .top, spacing: Self.columnSpacing) {
                PartySection(title: "Colors") {
                    PalettePicker(selection: look.isCustom
                                      ? PalettePicker.customID
                                      : look.palette(following: model.settings.palette).id,
                                  custom: .init(low: Color(effectsRGB: look.low),
                                                high: Color(effectsRGB: look.high))) { id in
                        if id == PalettePicker.customID {
                            model.setSceneCustomColors()
                        } else {
                            model.setScenePalette(id: id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
                    PartySection(title: "Brightness") {
                        if kind.usesDarkest(isCustom: look.isCustom) {
                            SceneLevelRow(title: "Darkest",
                                          value: look.floor,
                                          range: 0...(1 - GlowbeatSettings.minimumBrightnessSpan),
                                          color: look.isCustom ? look.low : nil,
                                          onChange: { model.setSceneFloor($0, persist: false) },
                                          onCommit: { model.setSceneFloor($0) },
                                          onColor: { model.setSceneLowColor($0) })
                        }
                        SceneLevelRow(title: "Brightest",
                                      value: look.ceiling,
                                      range: 0...1,
                                      color: look.isCustom ? look.high : nil,
                                      onChange: { model.setSceneCeiling($0, persist: false) },
                                      onCommit: { model.setSceneCeiling($0) },
                                      onColor: { model.setSceneHighColor($0) })
                    }

                    // Only Static has anything to do with this, so it only appears under
                    // Static rather than sitting there grayed out under the other four.
                    if kind.hasSingleColorMode {
                        Toggle("Single color",
                               isOn: Binding(get: { model.settings.sceneSingleColor },
                                             set: { model.setSceneSingleColor($0) }))
                            .toggleStyle(PartyCheckboxStyle())
                            .help("Put one color on every bulb instead of spreading the "
                                  + "colors along them.")
                    } else {
                        SceneSpeedSlider(speed: model.settings.sceneSpeed,
                                         onChange: { model.setSceneSpeed($0, persist: false) },
                                         onCommit: { model.setSceneSpeed($0) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(PartyStyle.sheetPadding)
        .tint(PartyStyle.accent)
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            sceneToggle
            // Labeled like the Effect and Palette pickers it sits under, so the popover
            // reads as one list of controls rather than one stray unlabeled row.
            picker
            if let progress = model.sceneProgress {
                SceneProgressView(progress: progress)
            }
        }
    }

    /// The switch, which the window shows in its section header and the popover shows
    /// inline.
    var sceneToggle: some View {
        Toggle(isOn: Binding(get: { isRunning },
                             set: { model.setSceneEnabled($0) })) {
            Label("Scenes", systemImage: "moon.stars")
        }
        .toggleStyle(.switch)
        .disabled(!hasReachableBulbs)
        .help(hasReachableBulbs
              ? "Slow light modes that do not listen to anything."
              : "Scenes need at least one bulb Glowbeat can reach.")
    }

    /// What the picker says about the chosen scene.
    ///
    /// The scene's own summary, except under Static, which now says where the simpler
    /// thing lives. Static and a still color do nearly the same job: Static holds one
    /// palette color on every bulb, the Colors pane holds one of twenty six curated
    /// colors with a brightness of its own. Static was left in place rather than removed,
    /// so it points at its replacement instead of quietly competing with it.
    ///
    /// The sentence is added here rather than in the Effects package, because the package
    /// has no idea the app has panes and should not learn.
    static func summary(for kind: SceneKind) -> String {
        guard kind == .fixed else { return kind.summary }
        return kind.summary + " For a single color, use Colors."
    }

    private var picker: some View {
        Picker("Scene", selection: Binding(get: { kind },
                                           set: { model.setScene(kind: $0) })) {
            ForEach(SceneKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
    }
}

/// How far through a scene that ends, which in practice means Sunset.
struct SceneProgressView: View {

    let progress: Double

    /// Whole minutes left, rounded up, so it never reads zero while it is still running.
    private var minutesLeft: Int {
        let remaining = SunsetScene.duration * (1 - min(1, max(0, progress)))
        return max(1, Int((remaining / 60).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(1, max(0, progress)))
                .progressViewStyle(.linear)
            Text("About \(minutesLeft) min left at this speed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Scene progress")
    }
}

/// The Speed slider, quarter speed through four times speed.
///
/// Logarithmic: the slider carries the exponent, so 1x sits in the middle and the same
/// drag either side of it halves or doubles the scene. A linear slider would spend three
/// quarters of its travel between 1x and 4x and squeeze everything slower than real time
/// into the first quarter.
struct SceneSpeedSlider: View {

    let speed: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    private static let exponentRange: ClosedRange<Double> = -2...2

    private var exponent: Double {
        log2(SceneKind.clampedSpeed(speed))
    }

    private var label: String {
        let value = SceneKind.clampedSpeed(speed)
        return value < 1
            ? String(format: "%.2fx", value)
            : String(format: "%.1fx", value)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Speed")
                .font(PartyStyle.label)
                .frame(width: LabeledValueSlider.labelWidth, alignment: .leading)
            Slider(value: Binding(get: { exponent },
                                  set: { onChange(pow(2, $0)) }),
                   in: Self.exponentRange) { editing in
                guard !editing else { return }
                onCommit(SceneKind.clampedSpeed(speed))
            }
            .accessibilityLabel("Scene speed")
            Text(label)
                .font(PartyStyle.readout)
                .monospacedDigit()
                .frame(width: LabeledValueSlider.readoutWidthDefault, alignment: .trailing)
        }
        .frame(minHeight: PartyStyle.rowHeight)
    }
}

/// One end of a scene: its brightness, and with custom colors the color it has there.
struct SceneLevelRow: View {

    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// Nil when the scene paints with a palette, which picks the color itself.
    let color: RGB?
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    let onColor: (RGB) -> Void

    var body: some View {
        HStack(spacing: 12) {
            LabeledValueSlider(title: title,
                               value: value,
                               range: range,
                               accessibilityLabel: "\(title) brightness",
                               onChange: onChange,
                               onCommit: onCommit)
            if let color {
                ColorPicker("\(title) color",
                            selection: Binding(get: { Color(effectsRGB: color) },
                                               set: { onColor(ColorConversion.effectsRGB(from: $0)) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .help("\(title) color")
            }
        }
    }
}

extension SceneKind {

    /// Whether the Darkest slider changes anything. A palette in Color flow or Static
    /// holds at the brightest, so Darkest only appears there with custom colors, where
    /// the low point is one of the two colors on show.
    func usesDarkest(isCustom: Bool) -> Bool {
        switch self {
        case .breathe, .candle, .sunset: return true
        case .colorFlow, .fixed: return isCustom
        }
    }
}
