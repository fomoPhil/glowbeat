import AppKit
import Effects
import SwiftUI

/// The popover behind the optional status item. Same `AppModel` as the window, fewer
/// controls: what someone reaches for mid song, and nothing else. White temperature and
/// per bulb aim stay in the window, where there is room for them.
struct MenuBarContentView: View {

    @Bindable var model: AppModel

    @Environment(\.openSettings) private var openSettings

    /// Wide enough for the Colors grid's longest row, which is Mood's nine swatches.
    ///
    /// It was 280 until the grid arrived. Nine 28 point cells and the eight 4 point gaps
    /// between them are 284 points, and 280 less the padding either side leaves 252, so
    /// the grid is the reason for the change and `MenuBarColorsTests` says so.
    static let popoverWidth: CGFloat = 320
    static let contentPadding: CGFloat = 14

    /// Which brightness the one slider in this popover is actually moving.
    ///
    /// There are two, and they are not the same store. `AppModel.setBrightness` is a raw
    /// command to every bulb that remembers nothing; `AppModel.setStillBrightness` is the
    /// Colors pane's persisted setting, the one a still color is sent at. So the slider
    /// follows the room: once a color has been put on the bulbs it is that color's
    /// brightness, and until then it is the plain All bulbs command it has always been.
    enum BrightnessTarget: Equatable, Sendable {
        case allBulbs
        case stillColor
    }

    static func brightnessTarget(appliedStillColor: StillColor?) -> BrightnessTarget {
        appliedStillColor == nil ? .allBulbs : .stillColor
    }

    /// Where the slider settles after a commit.
    ///
    /// The Colors brightness has a one percent floor, because zero is a bulb that is off
    /// rather than a brightness anyone chose. A slider left reading 0 while the bulbs
    /// went to 1 is a readout that lies, so the commit snaps the slider to what was
    /// really sent. The All bulbs command has no such floor: zero there is a command the
    /// user meant.
    static func settledPercent(_ percent: Double, target: BrightnessTarget) -> Double {
        switch target {
        case .allBulbs:
            return min(100, max(0, percent.rounded()))
        case .stillColor:
            return Double(StillColor.brightnessPercent(percent / 100))
        }
    }

    /// What the slider should read for the room as it is now.
    ///
    /// With a color applied that is the still brightness, so opening the popover on a
    /// room already wearing one shows the number the bulbs are really at. With nothing
    /// applied there is nothing to read back from: the bulbs report a brightness each,
    /// not one, so the slider keeps whatever was last asked for.
    static func syncedPercent(appliedStillColor: StillColor?,
                              stillBrightness: Double,
                              current: Double) -> Double {
        switch brightnessTarget(appliedStillColor: appliedStillColor) {
        case .allBulbs: return current
        case .stillColor: return Double(StillColor.brightnessPercent(stillBrightness))
        }
    }

    /// Matches the All bulbs row in the window: there is no single brightness to read
    /// back from many bulbs, so the slider shows what was last asked for and only sends
    /// when the drag ends.
    @State private var brightness: Double = 100

    private var hasReachableBulbs: Bool {
        model.bulbs.contains(where: \.isReachable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("All bulbs")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button("On") { model.setPower(true, for: nil) }
                    Button("Off") { model.setPower(false, for: nil) }
                }
                .controlSize(.small)

                HStack(spacing: 8) {
                    Slider(value: $brightness, in: 0...100) { editing in
                        guard !editing else { return }
                        commitBrightness()
                    }
                    .accessibilityLabel("Brightness for every bulb")
                    Text("\(Int(brightness.rounded()))%")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!hasReachableBulbs)

            Divider()

            MenuBarColorsSection(model: model)

            Divider()

            PartyToggle(model: model, style: .popover)

            Picker("Effect", selection: Binding(get: { model.settings.effectKind },
                                                set: { model.setEffect($0) })) {
                ForEach(EffectKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            Picker("Palette", selection: Binding(get: { model.settings.paletteID },
                                                 set: { model.setPalette(id: $0) })) {
                ForEach(Palette.all) { palette in
                    Text(palette.name).tag(palette.id)
                }
            }

            ConfettiToggle(model: model, style: .popover)

            LevelMeter(level: model.level)

            Divider()

            ScenesPanelView(model: model, style: .popover)

            Divider()

            HStack(spacing: 8) {
                Button("Settings") {
                    NSApplication.shared.activate()
                    openSettings()
                }
                Spacer(minLength: 8)
                Button("Quit Glowbeat") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(Self.contentPadding)
        .frame(width: Self.popoverWidth)
        .onAppear { syncBrightness() }
        .onChange(of: model.appliedStillColor?.id) { syncBrightness() }
        .onChange(of: model.settings.stillBrightness) { syncBrightness() }
    }

    private func commitBrightness() {
        let target = Self.brightnessTarget(appliedStillColor: model.appliedStillColor)
        let settled = Self.settledPercent(brightness, target: target)
        brightness = settled
        switch target {
        case .allBulbs:
            model.setBrightness(Int(settled), for: nil)
        case .stillColor:
            model.setStillBrightness(settled / 100)
        }
    }

    private func syncBrightness() {
        brightness = Self.syncedPercent(appliedStillColor: model.appliedStillColor,
                                        stillBrightness: model.settings.stillBrightness,
                                        current: brightness)
    }
}
