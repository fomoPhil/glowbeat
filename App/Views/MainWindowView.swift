import AppKit
import SwiftUI

/// The numbers the window is laid out from, in one place so a test can ask what fits.
///
/// The window used to have no minimum height at all: everything scrolled and both panels
/// collapsed. Layout B is four panes instead, each designed to need no scroller at the
/// size the mockup was drawn at, so the window now has a size it is meant to be and a
/// smallest size it still works at.
enum MainWindowMetrics {

    /// The smallest the window may be. The widest thing in the app is a bulb row, and the
    /// sidebar takes its width off the front of the pane, so this has to hold both.
    static let minimumWidth: CGFloat = 900
    static let minimumHeight: CGFloat = 640

    /// What the mockup was drawn at, and what the snapshots are rendered at.
    static let designWidth: CGFloat = 1000
    static let designHeight: CGFloat = 760

    /// What the window opens at.
    ///
    /// Taller than the mockup, and measured rather than guessed. The Party pane's content
    /// is 641 points with Advanced open and the Confetti switch under the palette, which
    /// is what it comes to once the panel is laid out in two columns; 760 leaves it 555
    /// once the title bar, the pane header, the bulb strip and the footer have taken
    /// theirs, and this leaves it 646. It was 820 until the Confetti row made the palette
    /// column the taller of the two by 66 points (2026-09-23). The mockup is HTML at an
    /// 11.5 point caption size and SwiftUI draws the same captions at 12, which is most of
    /// the rest of the difference. Phil's call if he would rather have the shorter window
    /// and a scroller.
    static let defaultHeight: CGFloat = 850

    /// The sidebar. Wider than the mockup's 214: the longest status line the four rows
    /// can print is "Wake 6:30 AM, sleep 11:00 PM", which measures 168 points, and a row
    /// spends 47 of its width on padding and the symbol. The minimum is what still leaves
    /// a bulb row room inside `minimumWidth`.
    static let sidebarMinimumWidth: CGFloat = 196
    static let sidebarIdealWidth: CGFloat = 236
    static let sidebarMaximumWidth: CGFloat = 280

    /// The window's own title bar with a toolbar in it, which `ImageRenderer` never
    /// draws, so a test measuring what fits has to subtract it by hand.
    static let titleBarHeight: CGFloat = 52
    /// The pane's title row: the name of the pane and the switch that starts it.
    static let paneHeaderHeight: CGFloat = 46
    /// The status line and the Setup guide button along the bottom.
    static let footerHeight: CGFloat = 34
    static let dividerHeight: CGFloat = 1

    /// How much room a pane's content really gets inside a window of this height.
    static func availablePaneHeight(windowHeight: CGFloat,
                                    showsBulbStrip: Bool) -> CGFloat {
        var height = windowHeight - titleBarHeight - paneHeaderHeight
            - footerHeight - dividerHeight
        if showsBulbStrip {
            height -= BulbStripMetrics.height + dividerHeight
        }
        return height
    }
}

/// The main window: a sidebar of four panes, the pane itself, the bulb strip along the
/// bottom and one status line under that.
struct MainWindowView: View {

    @Bindable var model: AppModel
    @State private var showsFirstRun = false

    private var pane: SidebarPane {
        model.selectedPane
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(
                        min: MainWindowMetrics.sidebarMinimumWidth,
                        ideal: MainWindowMetrics.sidebarIdealWidth,
                        max: MainWindowMetrics.sidebarMaximumWidth)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            // The window's own way into Settings, and the way to look again. The menu bar
            // popover has a button and Command comma works everywhere, but neither is
            // discoverable from the window, and `SettingsLink` is the only control macOS
            // lets open the Settings scene without going through `openSettings` and an
            // activation dance.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                        .help("Look for bulbs again")
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .help("Glowbeat settings")
                    .accessibilityLabel("Settings")
                }
            }

            // Every pane but Bulbs, which already is the list.
            if pane.showsBulbStrip {
                Divider()
                BulbStripView(model: model)
            }

            Divider()
            footer
        }
        .frame(minWidth: MainWindowMetrics.minimumWidth,
               minHeight: MainWindowMetrics.minimumHeight)
        // Only on an install that has never finished the walkthrough. Anyone who wants it
        // back gets it from the Setup guide button below rather than by wiping defaults.
        .onAppear { if !model.settings.hasCompletedFirstRun { showsFirstRun = true } }
        .sheet(isPresented: $showsFirstRun) {
            FirstRunSheet(model: model, isPresented: $showsFirstRun)
        }
    }

    // MARK: The pane

    @ViewBuilder
    var detail: some View {
        VStack(spacing: 0) {
            // `.noBulbs` is skipped on the Bulbs pane: the list already fills its whole
            // area with the same explanation and the same button, and saying it twice
            // looks broken.
            if let banner = model.banner, !(banner == .noBulbs && pane == .bulbs) {
                BannerView(model: model, banner: banner)
                Divider()
            }
            paneHeader
            ScrollView {
                paneContent
            }
        }
        // The detail column never asks the window for height. AppKit sizes the split
        // view from the minimum each column reports, and a column that reports more than
        // the window has is laid out taller than the window anyway: the whole root then
        // overflows both ends, centered, taking the sidebar's rows, the pane header, the
        // bulb strip and the footer off screen with it. That is what the audio banner
        // did when the music went quiet (2026-09-22). With both bounds given, this frame
        // takes whatever height it is offered, so the window's minimum stays where
        // `MainWindowMetrics` puts it whatever the pane is showing.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// The pane's name and the one switch that starts what it is for.
    @ViewBuilder
    var paneHeader: some View {
        HStack(spacing: 12) {
            Text(pane.title)
                .font(PartyStyle.paneTitle)
            Spacer(minLength: 8)
            switch pane {
            case .bulbs:
                EmptyView()
            case .party:
                PartyToggle(model: model, style: .paneHeader)
            case .scenes:
                ScenesPanelView(model: model).sceneToggle
                    .tint(PartyStyle.accent)
            case .colors:
                // No switch. A still color is not something that runs, so there is
                // nothing to turn off: the way out is to pick another color, start Party
                // Mode or a scene, or reach for the bulbs themselves in the strip below.
                EmptyView()
            case .schedule:
                // The Schedule pane's switch lives in the Schedule card's header, beside
                // the timers it turns on, because the Light card above it is always in
                // force and has no switch of its own to sit next to.
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(height: MainWindowMetrics.paneHeaderHeight)
    }

    /// What goes inside the pane's scroller, at its natural height.
    ///
    /// A property of its own because `ImageRenderer` draws nothing inside a `ScrollView`,
    /// so this is what the layout tests render and measure.
    @ViewBuilder
    var paneContent: some View {
        switch pane {
        case .bulbs:
            BulbListView(model: model)
        case .party:
            PartyPanelView(model: model, includesToggle: false, layout: .columns)
        case .scenes:
            ScenesPanelView(model: model, includesToggle: false)
        case .colors:
            ColorsPanelView(model: model)
        case .schedule:
            SchedulePanelView(model: model, layout: .columns)
        }
    }

    // MARK: The footer

    var footer: some View {
        HStack {
            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Setup guide") { showsFirstRun = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: MainWindowMetrics.footerHeight)
        .background(.quaternary.opacity(0.25))
    }
}

extension MainWindowView {

    /// The pane's content at the width the detail column really gives it. What the layout
    /// snapshot measures against the room the window has left over.
    func paneContent(width: CGFloat) -> some View {
        paneContent.frame(width: width)
    }

    /// The same window, laid out without `NavigationSplitView`.
    ///
    /// `ImageRenderer` will not lay a `NavigationSplitView` out: it draws a "not
    /// supported" glyph where the whole split should be, so a snapshot of the real window
    /// is a picture of a red circle. Every view here is the one the window uses, in the
    /// same order and at the same widths, so the image is of the real thing even though
    /// the container holding it is a plain `HStack`. Snapshots only.
    var snapshotLayout: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                SidebarView(model: model)
                    .frame(width: MainWindowMetrics.sidebarIdealWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.quaternary.opacity(0.35))
                Divider()
                VStack(spacing: 0) {
                    if let banner = model.banner, !(banner == .noBulbs && pane == .bulbs) {
                        BannerView(model: model, banner: banner)
                        Divider()
                    }
                    paneHeader
                    // Not the pane's `ScrollView`: `ImageRenderer` draws nothing inside
                    // one, so a snapshot of the window would be a picture of the sidebar
                    // and an empty rectangle.
                    paneContent
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)

            if pane.showsBulbStrip {
                Divider()
                BulbStripView(model: model, scrolls: false)
            }
            Divider()
            footer
        }
    }
}

/// The four panes, each with a live line underneath it saying what it is doing.
///
/// Hand rolled rather than a `List` with a selection, for the reason `PartySegmentedPicker`
/// is hand rolled: the stock control cannot carry the accent on the chosen row, and a
/// sidebar row in the 05 look is a raised amber-labeled surface rather than a system
/// selection highlight. Everything a picker owes anyone is still here: one accessibility
/// container, a selected trait on the chosen row, and a label on the group.
struct SidebarView: View {

    @Bindable var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarPane.allCases) { pane in
                item(for: pane)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(PartyStyle.motion(PartyStyle.quick, reduceMotion: reduceMotion),
                   value: model.selectedPane)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func item(for pane: SidebarPane) -> some View {
        let isSelected = pane == model.selectedPane
        return Button {
            model.setSelectedPane(pane)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(PartyStyle.accent)
                                                : AnyShapeStyle(.secondary))
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.title)
                        .font(PartyStyle.label)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(model.sidebarStatus(for: pane))
                        .font(PartyStyle.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(PartyStyle.accent)
                                                    : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: PartyStyle.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: PartyStyle.innerRadius + 1)
                        .fill(PartyStyle.raised)
                        .partyShadows(PartyStyle.liftShadows(colorScheme))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PartyStyle.innerRadius + 1))
        }
        .buttonStyle(PartyPressStyle())
        // A narrowed sidebar can still clip a status line, so the whole of it is a
        // tooltip away rather than lost to the ellipsis.
        .help("\(pane.title). \(model.sidebarStatus(for: pane))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(pane.title). \(model.sidebarStatus(for: pane))")
    }
}

/// The one banner slot at the top of the pane.
struct BannerView: View {

    @Bindable var model: AppModel
    let banner: AppModel.Banner

    /// The most lines the explanation under the title may take.
    ///
    /// A bound, not a style choice. The banner sits above the pane's scroller, so its
    /// height is part of the detail column's minimum, and that minimum is measured by
    /// offering the column no room at all. Text told to take whatever height it needs
    /// (`fixedSize` vertically, which this used to be) answers a zero width with one
    /// character per line: 1504 points for the audio banner, which the split view then
    /// honored by growing out of both ends of the window. Three lines hold every message
    /// at the narrowest window Glowbeat allows (the audio one needs all three at a 552
    /// point banner, and the narrowest real one is wider), and the whole of it is in the
    /// tooltip.
    static let detailLineLimit = 3

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(Self.detailLineLimit)
                    .truncationMode(.tail)
                    .help(detail)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
    }

    private var symbol: String {
        switch banner {
        case .noBulbs: return "lightbulb.slash"
        case .networkUnavailable: return "wifi.slash"
        case .audioDenied: return "speaker.slash"
        case .partyPaused: return "pause.circle"
        }
    }

    private var tint: Color {
        switch banner {
        case .noBulbs: return .secondary
        case .networkUnavailable: return .red
        case .audioDenied: return .red
        case .partyPaused: return .orange
        }
    }

    private var title: String {
        switch banner {
        case .noBulbs: return "No bulbs found"
        case .networkUnavailable: return "Network unavailable"
        case .audioDenied: return "Glowbeat is not hearing any audio"
        case .partyPaused(let reason): return reason
        }
    }

    private var detail: String {
        switch banner {
        case .noBulbs:
            return "Turn on LAN Control for each bulb in Govee Home, then scan again."
        case .networkUnavailable:
            return "Glowbeat could not open its network connection. Check that Wi-Fi is on and that this Mac is on the same network as the bulbs."
        case .audioDenied:
            return "Allow Glowbeat under Privacy & Security, Screen & System Audio Recording. Also check that something is playing and the Mac is not muted."
        case .partyPaused:
            return "Glowbeat stopped sending so it does not fight the Govee app."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch banner {
        case .noBulbs:
            Button("Scan again") { model.rescan() }
        case .networkUnavailable:
            Button("Try again") { model.restartNetwork() }
                .buttonStyle(.borderedProminent)
        case .audioDenied:
            Button("Open settings") { openAudioPrivacySettings() }
        case .partyPaused:
            Button("Resume") { model.resumeParty() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPartyTransitioning)
        }
    }

    /// Opens Privacy & Security, Screen & System Audio Recording, which is the pane the
    /// system audio tap is gated behind, not the microphone pane. Verified on macOS
    /// 26.6.2: `Privacy_AudioCapture` and `Privacy_ScreenCapture` both land on it.
    private func openAudioPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
