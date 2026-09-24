import SwiftUI

/// The Schedule pane: what white the room sits at, and when it lights up and goes out.
///
/// Two cards of equal weight. The Light card is the one that is always doing something,
/// because a light mode is always in force; the Schedule card is the one with a switch,
/// because timers are off until somebody asks for them.
struct SchedulePanelView: View {

    /// How the pane arranges its two cards.
    enum Layout {
        /// One above the other, for the Settings window, which is 500 points wide.
        case single
        /// Side by side, for the window's pane, which is 800 and not very tall.
        case columns
    }

    @Bindable var model: AppModel
    var layout: Layout = .columns

    /// The two things a timer cannot do for itself, said where the timer is set rather
    /// than discovered at half past six one morning.
    static let macAwakeNote = "Timers run while this Mac is awake. If it was asleep, the "
        + "lights catch up when it wakes."
    static let bulbPowerNote = "Bulbs need power to wake. Keep their switch on."

    static let lightModeCaption = "Daylight is a cool white for the day. Night is a warm "
        + "white that keeps you sleepy. Auto follows your Mac."

    private static let modeSegments: [PartySegment<LightMode>] =
        LightMode.allCases.map { PartySegment(value: $0, title: $0.displayName) }

    /// Between the two cards. The same gap the Party pane puts between its columns.
    private static let columnSpacing: CGFloat = 24

    var body: some View {
        cards
            .padding(PartyStyle.sheetPadding)
            .tint(PartyStyle.accent)
    }

    @ViewBuilder
    private var cards: some View {
        switch layout {
        case .single:
            VStack(alignment: .leading, spacing: PartyStyle.sectionSpacing) {
                lightCard
                scheduleCard
            }
        case .columns:
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                lightCard
                    .frame(maxWidth: .infinity, alignment: .leading)
                scheduleCard
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The switch in the Schedule card's header. The one control that decides whether
    /// either timer runs at all, so it sits on the card it belongs to rather than in the
    /// pane's title row: the Light card above it is always in force and has no switch.
    var scheduleToggle: some View {
        Toggle(isOn: Binding(get: { model.scheduleSettings.isEnabled },
                             set: { model.setScheduleEnabled($0) })) {
            Label("Schedule", systemImage: "clock")
        }
        .toggleStyle(.switch)
        .labelsHidden()
        .tint(PartyStyle.accent)
        .help("Light the room at your wake time and put it out at your sleep time.")
        .accessibilityLabel("Schedule")
    }

    // MARK: Light

    private var lightCard: some View {
        PartyCard(title: "Light") {
            VStack(alignment: .leading, spacing: PartyStyle.captionSpacing) {
                PartySegmentedPicker(segments: Self.modeSegments,
                                     selection: model.lightMode,
                                     accessibilityLabel: "Light mode",
                                     onSelect: { model.setLightMode($0) })

                Text(Self.lightModeCaption)
                    .font(PartyStyle.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.lightModeCaption)
                    .font(PartyStyle.caption)
                    .foregroundStyle(model.lightMode == .auto
                                     ? AnyShapeStyle(PartyStyle.accent)
                                     : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Now: \(model.lightModeCaption)")

                // Auto is the only mode that moves between two whites, so the slider that
                // says how slowly appears with it, the way Travel appears with Wave.
                if model.lightMode == .auto {
                    LabeledValueSlider(title: "Shift over",
                                       value: Double(model.settings.shiftLengthMinutes),
                                       range: 0...Double(GlowbeatSettings.maximumShiftLengthMinutes),
                                       snapsTo: 1,
                                       accessibilityLabel: "Shift over, how long Auto takes "
                                                           + "to change the white",
                                       format: ScheduleFormatting.minutes,
                                       onChange: { model.setShiftLength(minutes: Int($0.rounded()),
                                                                        persist: false) },
                                       onCommit: { model.setShiftLength(minutes: Int($0.rounded())) })
                    Text("How long Auto takes to move between the two whites. The Mac's "
                         + "own Night Shift fade is far too fast for a room light, so "
                         + "Glowbeat runs its own.")
                        .font(PartyStyle.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Schedule

    private var scheduleCard: some View {
        PartyCard(title: "Schedule") {
            scheduleToggle
        } content: {
            VStack(alignment: .leading, spacing: PartyStyle.captionSpacing) {
                wakeRow
                Divider()
                sleepRow

                if let line = ScheduleFormatting.nextEventLine(model.nextScheduleEvent,
                                                               at: Date()) {
                    Text(line)
                        .font(PartyStyle.readout)
                        .foregroundStyle(PartyStyle.accent)
                        .padding(.top, 2)
                }

                Text(Self.macAwakeNote)
                    .font(PartyStyle.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.bulbPowerNote)
                    .font(PartyStyle.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Every control in the card is dead while the switch is off, and dimming them
            // is what says so. The switch itself sits in the card's header, outside this.
            .disabled(!model.scheduleSettings.isEnabled)
            .opacity(model.scheduleSettings.isEnabled ? 1 : PartyStyle.disabledOpacity)
        }
    }

    private var wakeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimeOfDayRow(title: "Wake",
                         time: model.scheduleSettings.wakeTime,
                         help: "When the bulbs come on.",
                         onChange: { model.setWakeTime($0) })
            LabeledValueSlider(title: "Light up over",
                               value: Double(model.scheduleSettings.wakeRampMinutes),
                               range: 0...Double(ScheduleSettings.maximumRampMinutes),
                               snapsTo: 1,
                               accessibilityLabel: "Light up over, how long the wake takes",
                               format: ScheduleFormatting.minutes,
                               onChange: { model.setWakeRamp(minutes: Int($0.rounded()),
                                                             persist: false) },
                               onCommit: { model.setWakeRamp(minutes: Int($0.rounded())) })
            LabeledValueSlider(title: "To",
                               value: Double(model.scheduleSettings.wakeBrightness),
                               range: 1...100,
                               snapsTo: 1,
                               accessibilityLabel: "Wake brightness",
                               format: ScheduleFormatting.percent,
                               onChange: { model.setWakeBrightness(Int($0.rounded()),
                                                                   persist: false) },
                               onCommit: { model.setWakeBrightness(Int($0.rounded())) })
        }
    }

    private var sleepRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimeOfDayRow(title: "Sleep",
                         time: model.scheduleSettings.sleepTime,
                         help: "When the bulbs go out. Sleep always wins: it stops Party "
                               + "Mode or a scene first.",
                         onChange: { model.setSleepTime($0) })
            LabeledValueSlider(title: "Dim over",
                               value: Double(model.scheduleSettings.sleepRampMinutes),
                               range: 0...Double(ScheduleSettings.maximumRampMinutes),
                               snapsTo: 1,
                               accessibilityLabel: "Dim over, how long the sleep takes",
                               format: ScheduleFormatting.minutes,
                               onChange: { model.setSleepRamp(minutes: Int($0.rounded()),
                                                              persist: false) },
                               onCommit: { model.setSleepRamp(minutes: Int($0.rounded())) })
        }
    }
}

/// One time picker on a labeled row, in the same label column the sliders under it use so
/// the card reads as one stack rather than as a picker and then some sliders.
struct TimeOfDayRow: View {

    let title: String
    let time: TimeOfDay
    let help: String
    let onChange: (TimeOfDay) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(PartyStyle.label)
                .frame(width: LabeledValueSlider.labelWidth, alignment: .leading)
            Spacer(minLength: 8)
            DatePicker(title,
                       selection: Binding(get: { ScheduleFormatting.date(for: time) },
                                          set: { onChange(ScheduleFormatting.timeOfDay(from: $0)) }),
                       displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
                .help(help)
                .accessibilityLabel("\(title) time")
        }
        .frame(minHeight: PartyStyle.rowHeight)
    }
}

/// The Schedule tab in the Settings window: the same two cards, in the window someone
/// reaches for with Command comma.
///
/// The same views rather than a second copy of them, so a control added to the pane can
/// never be missing here.
struct ScheduleSettingsTab: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            SchedulePanelView(model: model, layout: .single)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
