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

    private var window: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 6) {
                picker
                    .pickerStyle(.segmented)
                    .labelsHidden()
                Text(Self.summary(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only Static has anything to do with this, so it only appears under Static
            // rather than sitting there grayed out under the other four.
            if kind.hasSingleColorMode {
                Toggle("Single color",
                       isOn: Binding(get: { model.settings.sceneSingleColor },
                                     set: { model.setSceneSingleColor($0) }))
                    .help("Put the palette's first color on every bulb instead of "
                          + "spreading the palette along them.")
            }

            SceneSpeedSlider(speed: model.settings.sceneSpeed,
                             onChange: { model.setSceneSpeed($0, persist: false) },
                             onCommit: { model.setSceneSpeed($0) })

            Text("Scenes use the same palette as Party Mode, and only one of the two runs "
                 + "at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
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
                .frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { exponent },
                                  set: { onChange(pow(2, $0)) }),
                   in: Self.exponentRange) { editing in
                guard !editing else { return }
                onCommit(SceneKind.clampedSpeed(speed))
            }
            .accessibilityLabel("Scene speed")
            Text(label)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
