import GoveeLAN
import SwiftUI

/// One bulb in the strip: its name, its switch, its brightness and the color it is on.
///
/// Small enough that six fit across the window, so everything that can be said in a
/// tooltip is: the brightness has no readout of its own and the full name is on hover.
/// Two things appear when the mouse is over it, the flash button and the drag affordance,
/// because a tile at rest should read as the state of a bulb rather than as a control
/// panel.
struct BulbStripTile: View {

    @Bindable var model: AppModel
    let bulb: Bulb
    /// Where this tile sits, 0 based. A tile dropped on this one takes this place.
    let index: Int

    @State private var controls = BulbControlValues()
    @State private var isEditingBrightness = false
    @State private var isHovering = false
    @State private var isTargeted = false
    @State private var showsColorPopover = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var name: String {
        model.displayName(for: bulb)
    }

    /// The flash button is on hover, but a control nobody can see is a control VoiceOver
    /// cannot reach either, so it stays visible whenever VoiceOver is running.
    private var showsFlash: Bool {
        isHovering || voiceOverEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            controlsRow
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: BulbStripMetrics.tileWidth,
               height: BulbStripMetrics.tileHeight,
               alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                .fill(PartyStyle.trough)
        }
        .overlay {
            RoundedRectangle(cornerRadius: PartyStyle.chipRadius)
                .strokeBorder(isTargeted ? PartyStyle.accent : .clear, lineWidth: 2)
        }
        .opacity(bulb.isReachable ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: PartyStyle.chipRadius))
        .onHover { isHovering = $0 }
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isHovering)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: isTargeted)
        // The tile is the handle. `draggable` carries the bulb id, and every other tile
        // is a drop destination for one, so a drag lands in the one stored order the list
        // and the strip both read.
        .draggable(bulb.id) {
            Text(name)
                .font(PartyStyle.caption)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            model.moveBulb(withID: dragged, toIndex: index)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .help("\(name), \(Int(controls.brightness.rounded()))%. Drag to reorder.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .task(id: bulb.id) { controls.sync(with: bulb.state, force: true, isFlashing: false) }
        .onChange(of: bulb.state) { _, newValue in
            controls.sync(with: newValue,
                          force: false,
                          isFlashing: model.isIdentifying(bulb),
                          isEditingBrightness: isEditingBrightness)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle("Power", isOn: Binding(get: { controls.power },
                                          set: { newValue in
                                              controls.power = newValue
                                              controls.touchPower()
                                              model.setPower(newValue, for: bulb)
                                          }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(PartyStyle.accent)
                .accessibilityLabel("Power for \(name)")

            Text(name)
                .font(PartyStyle.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            flashButton
        }
        .frame(height: 16)
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { controls.brightness },
                                  set: { controls.brightness = $0 }),
                   in: 0...100) { editing in
                isEditingBrightness = editing
                guard !editing else { return }
                controls.touchBrightness()
                model.setBrightness(Int(controls.brightness.rounded()), for: bulb)
            }
            .controlSize(.mini)
            .tint(PartyStyle.accent)
            .accessibilityLabel("Brightness for \(name)")
            .accessibilityValue("\(Int(controls.brightness.rounded())) percent")

            swatchButton
        }
        .frame(height: 18)
        .disabled(!bulb.isReachable)
    }

    /// The same flash the bulb row has had since v1, on the same rule: it sends one shot
    /// commands, so it may not run while Party Mode or a scene owns the bulbs.
    private var flashButton: some View {
        Button {
            model.identify(bulb)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(model.isIdentifying(bulb)
                                 ? AnyShapeStyle(PartyStyle.accent)
                                 : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsFlash ? 1 : 0)
        .disabled(!model.canIdentify || model.isIdentifying(bulb))
        .help(model.canIdentify
              ? "Blink this bulb"
              : "Turn Party Mode off to identify a bulb")
        .accessibilityLabel("Identify \(name)")
        .accessibilityHidden(!showsFlash)
    }

    /// The color the bulb is on, and the way to change it without leaving the pane you
    /// are in. A popover rather than the row's two inline controls: there is no room for
    /// a color well and a Kelvin slider inside 150 points.
    private var swatchButton: some View {
        Button {
            showsColorPopover = true
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(controls.swatchColor(for: bulb.state))
                .frame(width: 22, height: 16)
                // Every filled image gets a hairline of its own, so a pale white still
                // has an edge against a pale window.
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.black.opacity(0.18), lineWidth: 1)
                }
                // The visible swatch is smaller than anything anyone should have to hit.
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color and white for \(name)")
        .accessibilityLabel("Color for \(name)")
        .popover(isPresented: $showsColorPopover, arrowEdge: .top) {
            BulbColorPopover(model: model, bulb: bulb, controls: $controls)
        }
    }
}

/// The color and white controls for one bulb, on a popover.
///
/// The same two commands the bulb row sends, reached from a tile that has no room to show
/// them. It holds no state of its own: the tile's `BulbControlValues` is what it reads and
/// writes, so closing the popover and looking at the swatch shows what was just picked.
struct BulbColorPopover: View {

    @Bindable var model: AppModel
    let bulb: Bulb
    @Binding var controls: BulbControlValues

    private var name: String {
        model.displayName(for: bulb)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name)
                .font(PartyStyle.sectionTitle)

            HStack(spacing: 12) {
                Text("Color")
                    .font(PartyStyle.label)
                Spacer(minLength: 8)
                ColorPicker("Color for \(name)",
                            selection: $controls.color,
                            supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: controls.color) { _, newValue in
                        // Only a pick made by the user may send. A value a sync wrote
                        // into the well is dropped here.
                        guard controls.isUserColor(newValue) else { return }
                        controls.touchColor()
                        model.setColor(ColorConversion.effectsRGB(from: newValue), for: bulb)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("White")
                        .font(PartyStyle.label)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Int(controls.kelvin.rounded())) K")
                        .font(PartyStyle.readout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $controls.kelvin, in: ColorTemperatureRange.bounds) { editing in
                    guard !editing else { return }
                    controls.touchKelvin()
                    model.setColorTemperature(
                        kelvin: ColorTemperatureRange.clamp(Int(controls.kelvin.rounded())),
                        for: bulb)
                }
                .accessibilityLabel("White temperature for \(name)")
            }
        }
        .frame(width: 240)
        .padding(16)
        .tint(PartyStyle.accent)
    }
}
