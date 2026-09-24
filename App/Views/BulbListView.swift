import Effects
import GoveeLAN
import SwiftUI

/// The white range an H6004 actually reproduces. Offering Kelvin outside it would send
/// commands the hardware quietly ignores.
enum ColorTemperatureRange {
    static let minimum = 2700
    static let maximum = 6500
    static let neutral = 4000
    static var bounds: ClosedRange<Double> { Double(minimum)...Double(maximum) }

    static func clamp(_ kelvin: Int) -> Int {
        min(maximum, max(minimum, kelvin))
    }
}

/// How long a control keeps showing what the user chose before it will accept a polled
/// reading again. A one shot command is repeated three times a second apart and the next
/// status reply can land a second after that, so anything shorter lets a stale reading
/// snap the switch back and make the app look broken.
enum ControlSettle {
    static let duration: TimeInterval = 3

    static func isSettling(since changedAt: Date?, now: Date = Date()) -> Bool {
        guard let changedAt else { return false }
        return now.timeIntervalSince(changedAt) < duration
    }
}

/// Shared column widths so the header, the All bulbs row and every bulb row line up.
private enum RowMetrics {
    // Tighter than they were. The list used to have the whole window; it now has the
    // window less the sidebar, and a row that cannot compress has to fit inside that at
    // the smallest size the window is allowed to be. Nothing was dropped: every column is
    // the same column, a few points narrower.
    static let number: CGFloat = 24
    static let dot: CGFloat = 10
    static let name: CGFloat = 110
    static let power: CGFloat = 88
    static let slider: CGFloat = 78
    static let value: CGFloat = 40
    static let color: CGFloat = 40
    static let whiteSlider: CGFloat = 78
    static let whiteValue: CGFloat = 48
    static let identify: CGFloat = 40
    static let gap: CGFloat = 6
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 14

    /// Every row is exactly this tall.
    ///
    /// The bulb list lives inside the window's scroller now, so the `List` has its own
    /// scrolling switched off and is given a height instead. That height is this number
    /// times the number of bulbs, which only works while every row really is this tall,
    /// so the rows are pinned to it rather than left to their content.
    static let rowHeight: CGFloat = 40
    /// The rule `List` draws between two rows, which is part of what the list is tall
    /// enough to hold. The last row's separator is hidden, so there are one fewer of these
    /// than there are rows.
    static let rowSeparatorHeight: CGFloat = 1

    /// How tall a list of `count` bulbs is. Rounded up rather than down: a few points of
    /// slack under the last row cannot be seen, and a few points short of it clips the row.
    static func listHeight(forBulbCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSeparatorHeight
    }

    static var brightnessColumn: CGFloat { slider + gap + value }
    static var whiteColumn: CGFloat { whiteSlider + gap + whiteValue }

    /// Every column is a fixed width, so nothing in a row can compress. This is the
    /// width below which the last column starts falling off the end, and it is what the
    /// window's minimum width is built from rather than a number somebody guessed once.
    static var minimumRowWidth: CGFloat {
        let columns = number + dot + name + power + brightnessColumn + color
            + whiteColumn + identify
        // Eight gaps between the nine items in a row, and the padding on both sides.
        return columns + spacing * 8 + horizontalPadding * 2
    }
}

/// What the main window needs to show a bulb row without clipping it.
enum BulbListMetrics {
    /// One row's height, and how tall the whole list is for a given number of bulbs. The
    /// list has its own scrolling switched off inside the window's scroller, so this is
    /// the height it is given, and every row is pinned to it.
    static var rowHeight: CGFloat { RowMetrics.rowHeight }

    static func listHeight(forBulbCount count: Int) -> CGFloat {
        RowMetrics.listHeight(forBulbCount: count)
    }

    /// The row itself plus room for a list scroller, which overlays on macOS but can be
    /// set to be always visible in System Settings.
    static var minimumWidth: CGFloat { RowMetrics.minimumRowWidth + 16 }
}

struct BulbListView: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader()
            Divider()
            AllBulbsRow(model: model)
                .background(.quaternary.opacity(0.25))
            Divider()
            if model.bulbs.isEmpty {
                NoBulbsView(model: model)
            } else {
                // A `List` rather than the `LazyVStack` this used to be, because
                // `onMove` is what gives macOS drag and drop reordering for free. No
                // edit mode is involved: on the Mac a row in a list with `onMove` is
                // draggable as it stands.
                // A `List` rather than a stack, because `onMove` is what gives macOS
                // drag and drop reordering for free, but with its own scrolling switched
                // off and an exact height instead: the window's scroller is the only
                // thing that scrolls, so every bulb is visible and the section below
                // starts right under the last row rather than under a patch of nothing.
                List {
                    ForEach(Array(model.orderedBulbs.enumerated()), id: \.element.id) { entry in
                        BulbRow(model: model, bulb: entry.element, number: entry.offset + 1)
                            .listRowInsets(EdgeInsets())
                            // No rule under the last row: the list is followed by a
                            // divider of its own, and two lines together read as a gap.
                            .listRowSeparator(entry.offset == model.orderedBulbs.count - 1
                                              ? .hidden : .visible)
                    }
                    .onMove { source, destination in
                        model.moveBulbs(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, 1)
                .frame(height: RowMetrics.listHeight(forBulbCount: model.orderedBulbs.count))
            }
        }
    }
}

/// Tiny captions so the sliders and the color well are not a guessing game.
private struct ColumnHeader: View {

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            caption("#", width: RowMetrics.number, alignment: .center)
            Color.clear.frame(width: RowMetrics.dot, height: 1)
            caption("Bulb", width: RowMetrics.name, alignment: .leading)
            caption("Power", width: RowMetrics.power, alignment: .center)
            caption("Brightness", width: RowMetrics.brightnessColumn, alignment: .leading)
            caption("Color", width: RowMetrics.color, alignment: .center)
            caption("White", width: RowMetrics.whiteColumn, alignment: .leading)
            caption("Identify", width: RowMetrics.identify, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func caption(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

/// Shown instead of the list when discovery has found nothing.
struct NoBulbsView: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.networkUnavailable ? "Network unavailable" : "No bulbs found")
                .font(.headline)
            // With no network there is nothing LAN Control could fix, so the empty state
            // never sends the user into Govee Home for a Wi-Fi problem.
            Text(model.networkUnavailable
                 ? "Glowbeat could not open its network connection. Check that Wi-Fi is on, then try again."
                 : "Open Govee Home, tap each bulb, and turn on LAN Control. Then scan again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            Button(model.networkUnavailable ? "Try again" : "Scan again") {
                if model.networkUnavailable {
                    model.restartNetwork()
                } else {
                    model.rescan()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        // A height of its own rather than all the room there is: the empty state lives in
        // the window's scroller now, and a greedy one would push the Scenes and Party
        // panels out of the window.
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }
}

/// The row at the top that applies to every reachable bulb at once.
struct AllBulbsRow: View {

    @Bindable var model: AppModel

    @State private var brightness: Double = 100
    @State private var kelvin = Double(ColorTemperatureRange.neutral)
    @State private var color = Color.white
    /// The last color this row sent. The color well has no model value behind it, so
    /// this is what keeps a repeated pick from firing a second identical command.
    @State private var lastSentColor: Color?

    private var hasReachableBulbs: Bool {
        model.bulbs.contains(where: \.isReachable)
    }

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            Color.clear.frame(width: RowMetrics.number, height: 1)

            Image(systemName: "lightbulb.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .frame(width: RowMetrics.dot)

            Text("All bulbs")
                .font(.headline)
                .frame(width: RowMetrics.name, alignment: .leading)

            HStack(spacing: 6) {
                Button("On") { model.setPower(true, for: nil) }
                Button("Off") { model.setPower(false, for: nil) }
            }
            .controlSize(.small)
            .frame(width: RowMetrics.power)

            HStack(spacing: RowMetrics.gap) {
                Slider(value: $brightness, in: 0...100) { editing in
                    guard !editing else { return }
                    model.setBrightness(Int(brightness.rounded()), for: nil)
                }
                .frame(width: RowMetrics.slider)
                .help("Brightness for every bulb")
                .accessibilityLabel("Brightness for every bulb")

                Text("\(Int(brightness.rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.value, alignment: .trailing)
            }

            ColorPicker("Color for every bulb", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: RowMetrics.color)
                .onChange(of: color) { _, newValue in
                    guard newValue != lastSentColor else { return }
                    lastSentColor = newValue
                    model.setColor(ColorConversion.effectsRGB(from: newValue), for: nil)
                }

            HStack(spacing: RowMetrics.gap) {
                Slider(value: $kelvin, in: ColorTemperatureRange.bounds) { editing in
                    guard !editing else { return }
                    model.setColorTemperature(kelvin: ColorTemperatureRange.clamp(Int(kelvin.rounded())),
                                              for: nil)
                }
                .frame(width: RowMetrics.whiteSlider)
                .help("White temperature for every bulb, \(ColorTemperatureRange.minimum) K to \(ColorTemperatureRange.maximum) K")
                .accessibilityLabel("White temperature for every bulb")

                Text(verbatim: "\(Int(kelvin.rounded())) K")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.whiteValue, alignment: .trailing)
            }

            Color.clear.frame(width: RowMetrics.identify, height: 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .padding(.vertical, 10)
        .disabled(!hasReachableBulbs)
    }
}

/// One bulb: editable name, reachability, power, brightness, color, color temperature.
///
/// Every control here is optimistic. The bulbs answer a command by reporting their new
/// state on the next status poll, which is up to ten seconds away when Party Mode is
/// off, so a control that waited for the poll would visibly snap back to the old value
/// and then forward again. Each one shows what the user chose and only accepts a polled
/// reading once `ControlSettle.duration` has passed with no further change.
struct BulbRow: View {

    @Bindable var model: AppModel
    let bulb: Bulb
    /// The bulb's place in the list, 1 to N top to bottom. Shown so the number in a
    /// name like "Bulb 3" and the number in the row are the same number.
    let number: Int

    @State private var name = ""
    /// The switch, the two sliders and the well, and the rules about when a polled
    /// reading may move them. Shared with the strip tile, which draws the same bulb.
    @State private var controls = BulbControlValues()
    @State private var hasLoaded = false
    @State private var isHoveringHandle = false
    @State private var isHoveringRow = false

    @State private var isEditingBrightness = false
    @State private var isEditingKelvin = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            // The row's only grabbable surface, so it says so on hover. Everything to
            // the right of it is a control that takes the mouse down for itself, which
            // is what makes a bare number an undiscoverable place to start a drag.
            ZStack {
                Text("\(number)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(isHoveringHandle ? 0 : 1)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .opacity(isHoveringHandle ? 1 : 0)
            }
            .frame(width: RowMetrics.number)
            .contentShape(Rectangle())
            .onHover { isHoveringHandle = $0 }
            .help("Drag to reorder the bulbs")
            .accessibilityLabel("Position \(number). Drag to reorder.")

            Circle()
                .fill(bulb.isReachable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .frame(width: RowMetrics.dot)
                .help(bulb.isReachable ? "Reachable" : "Not answering. Check Wi-Fi.")
                .accessibilityLabel(bulb.isReachable ? "Reachable" : "Not reachable")

            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($isNameFocused)
                .frame(width: RowMetrics.name, alignment: .leading)
                .onSubmit { commitName() }
                .onChange(of: isNameFocused) { _, focused in
                    // Clicking away is how most people finish typing, so the name has to
                    // commit on focus loss as well as on Enter.
                    if !focused { commitName() }
                }

            Toggle("Power", isOn: Binding(
                get: { controls.power },
                set: { newValue in
                    controls.power = newValue
                    controls.touchPower()
                    model.setPower(newValue, for: bulb)
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: RowMetrics.power)
                .accessibilityLabel("Power for \(accessibleName)")

            HStack(spacing: RowMetrics.gap) {
                Slider(value: $controls.brightness, in: 0...100) { editing in
                    isEditingBrightness = editing
                    guard !editing else { return }
                    controls.touchBrightness()
                    model.setBrightness(Int(controls.brightness.rounded()), for: bulb)
                }
                .frame(width: RowMetrics.slider)
                .help("Brightness")
                .accessibilityLabel("Brightness for \(accessibleName)")

                Text("\(Int(controls.brightness.rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.value, alignment: .trailing)
            }

            ColorPicker("Color", selection: $controls.color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: RowMetrics.color)
                .accessibilityLabel("Color for \(accessibleName)")
                .onChange(of: controls.color) { _, newValue in
                    // Only a pick made by the user may send. A value this row wrote into
                    // the well during a sync is dropped here.
                    guard controls.isUserColor(newValue) else { return }
                    controls.touchColor()
                    model.setColor(ColorConversion.effectsRGB(from: newValue), for: bulb)
                }

            HStack(spacing: RowMetrics.gap) {
                Slider(value: $controls.kelvin, in: ColorTemperatureRange.bounds) { editing in
                    isEditingKelvin = editing
                    guard !editing else { return }
                    controls.touchKelvin()
                    model.setColorTemperature(
                        kelvin: ColorTemperatureRange.clamp(Int(controls.kelvin.rounded())),
                        for: bulb)
                }
                .frame(width: RowMetrics.whiteSlider)
                .help("White temperature, \(ColorTemperatureRange.minimum) K to \(ColorTemperatureRange.maximum) K")
                .accessibilityLabel("White temperature for \(accessibleName)")

                Text(verbatim: "\(Int(controls.kelvin.rounded())) K")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RowMetrics.whiteValue, alignment: .trailing)
            }

            Button {
                model.identify(bulb)
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    // The strip's tiles light their flash icon on hover. The row's is a
                    // column of its own and cannot appear and disappear without the
                    // header caption above it pointing at nothing, so it picks up the
                    // accent on hover instead of picking up its whole self.
                    .foregroundStyle(isHoveringRow && model.canIdentify
                                     ? AnyShapeStyle(PartyStyle.accent)
                                     : AnyShapeStyle(.primary))
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: RowMetrics.identify)
            .disabled(!model.canIdentify || model.isIdentifying(bulb))
            .help(model.canIdentify
                  ? "Blink this bulb so you can tell which one it is"
                  : "Turn Party Mode off to identify a bulb")
            .accessibilityLabel("Identify \(accessibleName)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, RowMetrics.horizontalPadding)
        .frame(height: RowMetrics.rowHeight)
        .opacity(bulb.isReachable ? 1 : 0.45)
        .disabled(!bulb.isReachable)
        .onHover { isHoveringRow = $0 }
        .task(id: bulb.id) { loadFromModel(force: true) }
        .onChange(of: bulb.state) { _, _ in loadFromModel(force: false) }
        // A bulb nobody has named is called by its place in the list, so dragging a row
        // renames it and everything it passed. Nothing else about the bulb changes, so
        // without this the field would keep saying "Bulb 3" until the next status poll.
        .onChange(of: number) { _, _ in reloadName() }
    }

    private var accessibleName: String {
        name.isEmpty ? model.displayName(for: bulb) : name
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = model.displayName(for: bulb)
            return
        }
        guard trimmed != model.displayName(for: bulb) else { return }
        name = trimmed
        model.setDisplayName(trimmed, for: bulb)
    }

    private func loadFromModel(force: Bool) {
        if force || !hasLoaded || !isNameFocused {
            name = model.displayName(for: bulb)
        }
        controls.sync(with: bulb.state,
                      force: force,
                      isFlashing: model.isIdentifying(bulb),
                      isEditingBrightness: isEditingBrightness,
                      isEditingKelvin: isEditingKelvin)
        hasLoaded = true
    }

    /// Only the name, for a row that moved. Nothing about the bulb itself changed, so the
    /// switch and the sliders are left exactly where they are.
    private func reloadName() {
        guard !isNameFocused else { return }
        name = model.displayName(for: bulb)
    }
}
