import SwiftUI

/// A bar that shows Glowbeat is hearing audio. Without it a silent Party Mode is
/// indistinguishable from a broken one.
///
/// Pass a `gate` to add the draggable Trigger Level marker. The bulbs stay at the
/// palette's dim base while the level is under it, and putting the control on the meter
/// rather than on a slider of its own is the point: the number only means something next
/// to the level it is judging.
///
/// Two looks, deliberately. With the marker it is the hero of the Party panel: a tall
/// segmented bar in neutral gray, so the amber marker is the only colored thing on it.
/// Without it, in the menu bar popover, it stays the slim gradient bar it has always
/// been, because the popover keeps its own look.
struct LevelMeter: View {

    let level: Float

    /// The party gate, 0 through 1, or nil for a read only meter.
    var gate: Double?
    /// False while Always react is on: the marker is grayed and cannot be dragged,
    /// because the value it shows is not what the room is running on. The bar underneath
    /// it stays live, which is the point of showing the meter at all.
    var isGateEnabled = true
    /// Called on every frame of a drag, so the room responds as the marker moves. This
    /// one must not write to disk.
    var onGateChange: ((Double) -> Void)?
    /// Called once when the drag ends. This is the one that commits the value.
    var onGateCommit: ((Double) -> Void)?

    /// Peak hold. The bar itself follows the audio, which at ten frames a second can
    /// look like flicker, so a slower marker rides on top and makes the movement read.
    @State private var peak: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// How far the marker falls each tick. At `ticksPerSecond` that is a fall from full
    /// scale to nothing in about three seconds.
    nonisolated static let decayPerTick: Double = 0.02
    nonisolated static let ticksPerSecond: Double = 16

    /// The read only bar stays slim and takes no space it does not need.
    nonisolated static let barHeight: CGFloat = 8
    /// The bar that carries the marker. Tall enough to read as the panel's one hero and
    /// to give the marker something to stand on.
    nonisolated static let gateBarHeight: CGFloat = 28
    /// How far the marker stands proud of the bar, top and bottom.
    nonisolated static let markerOverhang: CGFloat = 6
    nonisolated static let markerWidth: CGFloat = 3
    nonisolated static let markerHeight: CGFloat = 40
    /// The grip under the marker: the part that says "this is draggable" without a
    /// tooltip, and the widest part of the target.
    nonisolated static let gripWidth: CGFloat = 26
    nonisolated static let gripHeight: CGFloat = 11
    /// The whole row: the bar, the marker standing above it, and the grip hanging below.
    nonisolated static let gateRowHeight: CGFloat = 50
    /// Segments, which is what turns a bar into a meter. A fixed count rather than one
    /// per point of width, so the meter reads the same at every window size.
    nonisolated static let segmentCount = 48
    nonisolated static let segmentSpacing: CGFloat = 2
    /// How far one press of an arrow key moves the marker under VoiceOver.
    nonisolated static let accessibilityStep: Double = 0.05
    /// What the marker and the readout beside it fade to while Always react is on. The
    /// panel's one disabled amount, shared with every control that can be dimmed, so a
    /// grayed marker and a dimmed button cannot drift apart.
    nonisolated static let disabledOpacity: Double = PartyStyle.disabledOpacity

    /// Where the marker sits after one tick. Pure, so the rise and the fall can be
    /// tested without a view.
    ///
    /// A louder reading is taken immediately, a quieter one is approached a step at a
    /// time, and the marker never falls below the bar it is riding on.
    nonisolated static func nextPeak(current: Double, previous: Double) -> Double {
        let now = min(1, max(0, current))
        guard now < previous else { return now }
        return max(now, previous - decayPerTick)
    }

    /// The gate a drag to `x` across a bar of `width` means. Pure, so the clamping at
    /// both ends can be tested without a view.
    nonisolated static func gate(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private var clamped: Double {
        min(1, max(0, Double(level)))
    }

    private var clampedGate: Double {
        min(1, max(0, gate ?? 0))
    }

    /// Only a meter that carries the marker needs the taller row.
    private var rowHeight: CGFloat {
        gate == nil ? Self.barHeight : Self.gateRowHeight
    }

    var body: some View {
        GeometryReader { geometry in
            // The timeline is what makes the peak marker fall during silence. Silence
            // stops the audio frames, so `level` stops changing and anything driven only
            // by its changes would leave the marker frozen at the last loud moment. The
            // closure is re-evaluated on every tick, so the decay always reads the live
            // `level` rather than whatever it was when the view first appeared.
            TimelineView(.periodic(from: .now, by: 1 / Self.ticksPerSecond)) { context in
                ZStack(alignment: .topLeading) {
                    bar(width: geometry.size.width)
                    if gate != nil {
                        gateMarker(width: geometry.size.width)
                    }
                }
                .frame(width: geometry.size.width,
                       height: rowHeight,
                       alignment: .topLeading)
                .modifier(GateDragging(isEnabled: gate != nil && isGateEnabled,
                                       gesture: gateDrag(width: geometry.size.width)))
                .onChange(of: context.date) { _, _ in
                    peak = Self.nextPeak(current: clamped, previous: peak)
                }
            }
        }
        .frame(height: rowHeight)
        // A louder reading should not wait up to a tick to show, so it is taken the
        // moment it arrives as well.
        .onChange(of: level) { _, _ in
            peak = Self.nextPeak(current: clamped, previous: peak)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        if gate == nil {
            popoverBar(width: width)
        } else {
            SegmentedMeter(level: clamped,
                           peak: peak,
                           width: width,
                           reduceMotion: reduceMotion)
                .padding(.top, Self.markerOverhang)
                .accessibilityElement()
                .accessibilityLabel("Audio level")
                .accessibilityValue("\(Int(clamped * 100)) percent")
        }
    }

    /// The menu bar popover's meter, unchanged: a slim gradient capsule with a peak line.
    private func popoverBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))

            Capsule()
                .fill(LinearGradient(colors: [.green, .yellow, .orange],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(width: max(0, width * clamped))
                .animation(PartyStyle.motion(.easeOut(duration: 0.08),
                                             reduceMotion: reduceMotion),
                           value: clamped)

            Capsule()
                .fill(Color.primary.opacity(0.45))
                .frame(width: 2)
                .offset(x: max(0, width * peak - 1))
                .opacity(peak > 0.01 ? 1 : 0)
                .animation(PartyStyle.motion(.easeOut(duration: 0.1),
                                             reduceMotion: reduceMotion),
                           value: peak)
        }
        .frame(height: Self.barHeight)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }

    private func gateMarker(width: CGFloat) -> some View {
        TriggerMarker(isEnabled: isGateEnabled, colorScheme: colorScheme)
            .offset(x: max(0, width * clampedGate - Self.markerWidth / 2))
            .help(isGateEnabled
                  ? "Trigger Level: \(percentText)"
                  : "Always react is on, so the lights react at every level.")
            // Disabled rather than merely dimmed, so VoiceOver says so and the arrow key
            // adjustment below cannot move a marker nothing is reading.
            .disabled(!isGateEnabled)
            .accessibilityElement()
            .accessibilityLabel("Trigger Level")
            .accessibilityValue(percentText)
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
                // One keypress is one deliberate change, so it commits straight away.
                onGateCommit?(min(1, max(0, clampedGate + step)))
            }
    }

    /// The same form the readouts beside the bar and in Settings use, so the tooltip,
    /// the label and the number on screen never disagree.
    private var percentText: String {
        "\(Int((clampedGate * 100).rounded()))%"
    }

    /// Zero minimum distance so a click anywhere on the bar places the marker rather than
    /// making the user find the three points it currently occupies.
    private func gateDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onGateChange?(Self.gate(atX: value.location.x, width: width))
            }
            .onEnded { value in
                onGateCommit?(Self.gate(atX: value.location.x, width: width))
            }
    }
}

/// The lit bar itself: neutral segments, a lit run up to the level, and a fainter run out
/// to the held peak.
///
/// The three runs are plain rectangles behind one mask of 48 segments rather than three
/// stacks of 48 shapes. The mask never changes, so the only thing that moves sixteen
/// times a second is the width of two rectangles.
private struct SegmentedMeter: View {

    let level: Double
    let peak: Double
    let width: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(PartyStyle.meterOff)
            Rectangle()
                .fill(PartyStyle.meterPeak)
                .frame(width: max(0, width * peak))
                .animation(PartyStyle.motion(.easeOut(duration: 0.1),
                                             reduceMotion: reduceMotion),
                           value: peak)
            Rectangle()
                .fill(PartyStyle.meterOn)
                .frame(width: max(0, width * level))
                .animation(PartyStyle.motion(.easeOut(duration: 0.08),
                                             reduceMotion: reduceMotion),
                           value: level)
        }
        .frame(width: width, height: LevelMeter.gateBarHeight, alignment: .leading)
        .mask { SegmentComb() }
    }
}

/// The comb of segments every meter run is drawn through.
private struct SegmentComb: View {

    var body: some View {
        HStack(spacing: LevelMeter.segmentSpacing) {
            ForEach(0..<LevelMeter.segmentCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The Trigger Level marker: the one accent shape on the meter, with the grip under it
/// that makes it read as draggable.
private struct TriggerMarker: View {

    let isEnabled: Bool
    let colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2)
                .fill(PartyStyle.accent)
                .frame(width: LevelMeter.markerWidth, height: LevelMeter.markerHeight)
                .shadow(color: PartyStyle.accent.opacity(0.35), radius: 7)
            RoundedRectangle(cornerRadius: 4)
                .fill(PartyStyle.accent)
                .frame(width: LevelMeter.gripWidth, height: LevelMeter.gripHeight)
                .partyShadows(PartyStyle.liftShadows(colorScheme))
                .offset(y: LevelMeter.markerHeight - 2)
        }
        .frame(width: LevelMeter.markerWidth, alignment: .top)
        .opacity(isEnabled ? 1 : LevelMeter.disabledOpacity)
        // The drawn marker is three points wide. The thing anyone has to hit is this.
        .contentShape(Rectangle().size(width: PartyStyle.hitTarget,
                                       height: LevelMeter.gateRowHeight)
            .offset(x: -(PartyStyle.hitTarget - LevelMeter.markerWidth) / 2))
    }
}

/// Adds the drag target only to a meter that carries the gate marker. A read only meter
/// keeps no hit region at all, so it cannot swallow a click meant for what is behind it.
private struct GateDragging<G: Gesture>: ViewModifier {

    let isEnabled: Bool
    let gesture: G

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .gesture(gesture)
        } else {
            content
        }
    }
}
