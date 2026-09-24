import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
@testable import Glowbeat

/// Covers what the Settings scene and the menu bar popover read and write. The views
/// themselves are SwiftUI value types, so what is worth testing is the model API behind
/// every control plus the one piece of display logic the picker owns.
@MainActor
final class SettingsSceneTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    /// Every model this suite builds gets this, so no test can reach `SMAppService`.
    private var loginItems = FakeLoginItemService()

    private func makeModel() throws -> AppModel {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return AppModel(socket: socket,
                        discovery: BulbDiscovery(socket: socket, configuration: configuration),
                        controller: BulbController(socket: socket),
                        poller: StatusPoller(socket: socket, configuration: configuration),
                        frameSource: ScriptedFrameSource(),
                        tickSource: ManualTickSource(),
                        settingsStore: SettingsStore(defaults: defaults),
                        nameStore: BulbNameStore(defaults: defaults),
                        loginItems: loginItems)
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        loginItems = FakeLoginItemService()
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: The scenes

    func testBothScenesBuildFromTheSameModel() throws {
        let model = try makeModel()
        let settings = SettingsView(model: model)
        let menuBar = MenuBarContentView(model: model)
        XCTAssertTrue(settings.model === model)
        XCTAssertTrue(menuBar.model === model)
    }

    /// Rendering is the only cheap way to prove a SwiftUI body evaluates. The popover in
    /// particular is never on screen during a build, so without this a crash in it would
    /// only show up in front of the user.
    func testBothViewBodiesRender() throws {
        let model = try makeModel()
        let popover = ImageRenderer(content: MenuBarContentView(model: model))
        XCTAssertNotNil(popover.nsImage)
        let settings = ImageRenderer(content: SettingsView(model: model)
            .frame(width: 460, height: 420))
        XCTAssertNotNil(settings.nsImage)
        let windowToggle = ImageRenderer(content: PartyToggle(model: model, style: .window)
            .frame(width: 460))
        XCTAssertNotNil(windowToggle.nsImage)
        let popoverToggle = ImageRenderer(content: PartyToggle(model: model, style: .popover)
            .frame(width: 280))
        XCTAssertNotNil(popoverToggle.nsImage)
        let partyPanel = ImageRenderer(content: PartyPanelView(model: model)
            .frame(width: 460))
        XCTAssertNotNil(partyPanel.nsImage)
        // Travel only exists while Wave is the chosen effect, so that branch of the panel
        // would otherwise never be evaluated by a test.
        model.setEffect(.wave)
        let wavePanel = ImageRenderer(content: PartyPanelView(model: model)
            .frame(width: 460))
        XCTAssertNotNil(wavePanel.nsImage)
        model.setEffect(.pulse)
        let scenes = ImageRenderer(content: ScenesPanelView(model: model)
            .frame(width: 460))
        XCTAssertNotNil(scenes.nsImage)
        let scenesPopover = ImageRenderer(content: ScenesPanelView(model: model, style: .popover)
            .frame(width: 280))
        XCTAssertNotNil(scenesPopover.nsImage)
        let progress = ImageRenderer(content: SceneProgressView(progress: 0.5)
            .frame(width: 180))
        XCTAssertNotNil(progress.nsImage)
        // The main window carries the Settings toolbar item, so rendering it is what
        // proves that item builds.
        let window = ImageRenderer(content: MainWindowView(model: model)
            .frame(width: 880, height: 720))
        XCTAssertNotNil(window.nsImage)
    }

    /// With Always react on, the marker and its readout render grayed while the bar keeps
    /// moving. That is a branch of both windows no other render test reaches.
    func testBothWindowsRenderWithAlwaysReactOn() throws {
        let model = try makeModel()
        model.setAlwaysReacts(true)
        let panel = ImageRenderer(content: PartyPanelView(model: model)
            .frame(width: 460))
        XCTAssertNotNil(panel.nsImage)
        let settings = ImageRenderer(content: SettingsView(model: model)
            .frame(width: 460, height: 420))
        XCTAssertNotNil(settings.nsImage)
        let meter = ImageRenderer(content: LevelMeter(level: 0.5,
                                                      gate: 0.4,
                                                      isGateEnabled: false)
            .frame(width: 200))
        XCTAssertNotNil(meter.nsImage)
    }

    /// The window has no minimum height any more: the two panels collapse and scroll, so
    /// it has to lay out on a short laptop display as readily as on a tall one.
    func testTheWindowLaysOutOnAShortDisplay() throws {
        let model = try makeModel()
        for height in [560.0, 600.0, 720.0, 1000.0] {
            let renderer = ImageRenderer(content: MainWindowView(model: model)
                .frame(width: 880, height: height))
            let image = try XCTUnwrap(renderer.nsImage, "The window did not lay out at \(height).")
            XCTAssertEqual(image.size.height, height, accuracy: 1,
                           "The window grew past the height it was given.")
            XCTAssertEqual(image.size.width, 880, accuracy: 1)
        }
    }

    /// Both sections closed is the shortest the window can be, and it still has to render
    /// the bulb list, both headers and the status line.
    func testTheWindowLaysOutWithBothSectionsCollapsed() throws {
        let model = try makeModel()
        model.setScenesSectionExpanded(false)
        model.setPartySectionExpanded(false)
        let renderer = ImageRenderer(content: MainWindowView(model: model)
            .frame(width: 880, height: 420))
        XCTAssertNotNil(renderer.nsImage)
        XCTAssertFalse(model.settings.showsScenesSection)
        XCTAssertFalse(model.settings.showsPartySection)
    }

    /// Static is the only scene with a single color mode, and the switch writes through.
    func testTheSingleColorSwitchWritesThrough() throws {
        let model = try makeModel()
        XCTAssertFalse(model.settings.sceneSingleColor)
        model.setSceneSingleColor(true)
        XCTAssertTrue(model.settings.sceneSingleColor)
        XCTAssertTrue(SceneKind.fixed.hasSingleColorMode)
        for kind in SceneKind.allCases where kind != .fixed {
            XCTAssertFalse(kind.hasSingleColorMode, kind.displayName)
        }
    }

    // MARK: Scenes

    /// The speed slider carries the exponent, so 1x sits in the middle of its travel and
    /// the same drag either side of it halves or doubles the scene.
    func testTheSpeedSliderIsLogarithmic() {
        var committed: [Double] = []
        let slider = SceneSpeedSlider(speed: 1, onChange: { committed.append($0) }, onCommit: { _ in })
        XCTAssertNotNil(ImageRenderer(content: slider.frame(width: 300)).nsImage)
        // The mapping itself, which is what the slider's binding does in both directions.
        XCTAssertEqual(pow(2, log2(SceneKind.clampedSpeed(1))), 1, accuracy: 0.0001)
        XCTAssertEqual(pow(2, log2(SceneKind.clampedSpeed(0.25))), 0.25, accuracy: 0.0001)
        XCTAssertEqual(pow(2, log2(SceneKind.clampedSpeed(4))), 4, accuracy: 0.0001)
    }

    /// The picker writes through and is remembered, whether or not a scene is running.
    func testThePickerWritesTheSceneThrough() throws {
        let model = try makeModel()
        XCTAssertEqual(model.settings.sceneKind, .breathe)
        model.setScene(kind: .candle)
        XCTAssertEqual(model.settings.sceneKind, .candle)
        XCTAssertEqual(model.sceneState, .off, "Picking a scene must not start one.")
    }

    // MARK: General

    func testTheMenuBarExtraIsOffByDefaultAndTogglesOn() throws {
        let model = try makeModel()
        XCTAssertFalse(model.settings.showsMenuBarExtra)
        model.setShowsMenuBarExtra(true)
        XCTAssertTrue(model.settings.showsMenuBarExtra)
        model.setShowsMenuBarExtra(false)
        XCTAssertFalse(model.settings.showsMenuBarExtra)
    }

    /// macOS is the only thing that can turn the status item off behind the user's back,
    /// by evicting it from a full menu bar, and SwiftUI reports that eviction by writing
    /// `false` into the `isInserted` binding. The setting must survive that, so the
    /// binding rides the separate record of what macOS did.
    func testAnEvictionIsRecordedWithoutTouchingTheStoredSetting() throws {
        let model = try makeModel()
        let isInserted = GlowbeatApp.menuBarInsertionBinding(model: model)

        model.setShowsMenuBarExtra(true)
        XCTAssertTrue(model.settings.showsMenuBarExtra)
        XCTAssertTrue(isInserted.wrappedValue, "Turning the setting on has to ask for the item.")

        // macOS evicting the item.
        isInserted.wrappedValue = false
        XCTAssertTrue(model.settings.showsMenuBarExtra,
                      "An eviction must never undo what the user chose.")
        XCTAssertFalse(isInserted.wrappedValue,
                       "The scene has to be told the item is gone, or it asks again forever.")

        // Settings turning it off, which is the only thing that may.
        model.setShowsMenuBarExtra(false)
        XCTAssertFalse(model.settings.showsMenuBarExtra)
        XCTAssertFalse(isInserted.wrappedValue)
    }

    /// The hang this test exists for: on a full menu bar macOS evicted the status item as
    /// fast as SwiftUI added it, the binding answered every eviction with `true` again,
    /// and the `App` body re-ran on every pass of the run loop until the user force quit.
    ///
    /// This is that handshake. Every iteration is one scene update: read the binding, and
    /// if it says the item belongs on the bar, a full bar evicts it and SwiftUI writes
    /// `false` straight back. It has to settle, and one attempt is the whole budget.
    func testAFullMenuBarSettlesAfterASingleInsertionAttempt() throws {
        let model = try makeModel()
        let isInserted = GlowbeatApp.menuBarInsertionBinding(model: model)
        model.setShowsMenuBarExtra(true)

        var insertionAttempts = 0
        for _ in 0..<1_000 {
            guard isInserted.wrappedValue else { break }
            insertionAttempts += 1
            isInserted.wrappedValue = false
        }

        XCTAssertEqual(insertionAttempts, 1,
                       "A rejected insertion must not be retried on the next update pass.")
        XCTAssertTrue(model.settings.showsMenuBarExtra,
                      "The user's setting stays on. Settings still offers to turn it off.")
    }

    /// Making room and asking again has to work, or the only cure for one eviction would
    /// be relaunching the app.
    func testTurningTheSettingOffAndOnAsksForTheItemAgain() throws {
        let model = try makeModel()
        let isInserted = GlowbeatApp.menuBarInsertionBinding(model: model)

        model.setShowsMenuBarExtra(true)
        isInserted.wrappedValue = false
        XCTAssertFalse(isInserted.wrappedValue)

        model.setShowsMenuBarExtra(false)
        model.setShowsMenuBarExtra(true)
        XCTAssertTrue(isInserted.wrappedValue)
    }

    /// `@Observable` invalidates on every write, equal or not, and `settings` is a single
    /// property, so a redundant write re-runs everything that reads any setting at all.
    func testWritingTheSameMenuBarSettingTwiceInvalidatesNothing() throws {
        let model = try makeModel()
        model.setShowsMenuBarExtra(true)

        let changed = Flag()
        withObservationTracking {
            _ = model.settings.showsMenuBarExtra
        } onChange: {
            changed.raise()
        }

        model.setShowsMenuBarExtra(true)
        XCTAssertFalse(changed.isRaised, "Setting a value to what it already is is not a change.")
    }

    /// The `App` body reads this binding, so whatever the getter touches is re-evaluated
    /// on every write to it. Reading `settings` here would put the whole scene list, and
    /// the Settings window it builds, behind every frame of a party gate drag.
    func testTheMenuBarBindingDoesNotObserveEveryOtherSetting() throws {
        let model = try makeModel()
        let isInserted = GlowbeatApp.menuBarInsertionBinding(model: model)

        let changed = Flag()
        withObservationTracking {
            _ = isInserted.wrappedValue
        } onChange: {
            changed.raise()
        }

        model.setPartyGate(0.42)
        model.setEffect(.wave)
        XCTAssertFalse(changed.isRaised,
                       "Only the insertion state may re-run the App body.")
    }

    /// `SettingsView.init` runs inside the `App` body on every update pass, open window or
    /// not. Asking `SMAppService` for its status there was a blocking XPC round trip per
    /// pass, which is what turned the menu bar loop into a beach ball. A thousand of these
    /// take microseconds without it and the better part of a second with it.
    func testBuildingTheSettingsViewDoesNotCallOutToAnotherProcess() throws {
        let model = try makeModel()
        let started = Date()
        var built = 0
        for _ in 0..<1_000 {
            let view = SettingsView(model: model)
            built += view.model === model ? 1 : 0
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(built, 1_000)
        XCTAssertLessThan(elapsed, 1,
                          "Building the Settings view must not block on another process.")
    }

    /// The note only speaks once the service has actually been asked, and never claims
    /// more than macOS did.
    func testTheLoginItemNoteFollowsTheServiceState() {
        XCTAssertNil(SettingsView.loginItemNote(launchesAtLogin: false, status: .notRegistered))
        XCTAssertNil(SettingsView.loginItemNote(launchesAtLogin: true, status: nil),
                     "Nothing to say before the service has been asked.")
        XCTAssertNil(SettingsView.loginItemNote(launchesAtLogin: true, status: .enabled))
        XCTAssertEqual(SettingsView.loginItemNote(launchesAtLogin: true, status: .requiresApproval),
                       "macOS is waiting for you to allow Glowbeat under Login Items.")
        XCTAssertEqual(SettingsView.loginItemNote(launchesAtLogin: true, status: .notRegistered),
                       "macOS has not turned this on. Check Glowbeat under Login Items.")
        XCTAssertEqual(SettingsView.loginItemNote(launchesAtLogin: true, status: .notFound),
                       "macOS has not turned this on. Check Glowbeat under Login Items.")
    }

    /// Both directions of the rule that the login item's real state wins.
    ///
    /// The service is faked, so the suite never registers a real login item, and the one
    /// path the real service cannot be asked for on demand is covered here: a
    /// registration that macOS accepts into `.requiresApproval` rather than `.enabled`.
    func testLaunchAtLoginSettingMatchesTheRegisteredServiceState() throws {
        let model = try makeModel()
        loginItems.statusAfterRegister = .enabled
        model.setLaunchesAtLogin(true)
        XCTAssertEqual(loginItems.registerCount, 1)
        XCTAssertTrue(model.settings.launchesAtLogin)

        model.setLaunchesAtLogin(false)
        XCTAssertEqual(loginItems.unregisterCount, 1)
        XCTAssertFalse(model.settings.launchesAtLogin)
    }

    /// macOS accepting the registration is not the same as macOS having turned it on.
    func testARegistrationHeldForApprovalLeavesTheSettingOff() throws {
        let model = try makeModel()
        loginItems.statusAfterRegister = .requiresApproval
        model.setLaunchesAtLogin(true)
        XCTAssertEqual(loginItems.registerCount, 1)
        XCTAssertFalse(model.settings.launchesAtLogin,
                       "The setting must report what macOS did, not what was asked for.")
        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
    }

    /// A registration that throws must not leave the toggle claiming it worked.
    func testAFailedRegistrationLeavesTheSettingOff() throws {
        let model = try makeModel()
        loginItems.errorToThrow = CocoaError(.fileNoSuchFile)
        model.setLaunchesAtLogin(true)
        XCTAssertEqual(loginItems.registerCount, 1)
        XCTAssertFalse(model.settings.launchesAtLogin)
    }

    /// No test may ever touch the real service: the model has to take one by injection
    /// and use nothing else.
    func testTheModelNeverReachesTheRealLoginItemService() throws {
        let model = try makeModel()
        _ = model.loginItemStatus
        model.setLaunchesAtLogin(true)
        model.setLaunchesAtLogin(false)
        XCTAssertGreaterThan(loginItems.statusReads, 0)
        XCTAssertEqual(loginItems.registerCount, 1)
        XCTAssertEqual(loginItems.unregisterCount, 1)
    }

    // MARK: Network

    func testTheRescanIntervalIsClampedToFifteenThroughThreeHundred() throws {
        let model = try makeModel()
        model.setRescanInterval(1)
        XCTAssertEqual(model.settings.rescanInterval, 15)
        model.setRescanInterval(9999)
        XCTAssertEqual(model.settings.rescanInterval, 300)
        model.setRescanInterval(120)
        XCTAssertEqual(model.settings.rescanInterval, 120)
    }

    func testEveryRescanChoiceIsSelectableAndSurvivesAReload() throws {
        let model = try makeModel()
        for choice in SettingsView.rescanChoices {
            model.setRescanInterval(choice)
            XCTAssertEqual(model.settings.rescanInterval, choice)
            XCTAssertEqual(SettingsView.nearestRescanChoice(to: model.settings.rescanInterval),
                           choice)
        }
    }

    func testAnIntervalOutsideTheChoicesShowsAsTheNearestChoice() {
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 15), 15)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 20), 15)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 45), 30)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 61), 60)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 200), 120)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 299), 300)
        // Values the clamp would never allow still have to resolve to a row rather than
        // leave the picker blank.
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 0), 15)
        XCTAssertEqual(SettingsView.nearestRescanChoice(to: 100_000), 300)
    }

    /// "Trigger Level" is a wider label than the "Reacts to" it replaced, and the column
    /// it sits in is shared with every slider so the bars and readouts line up down the
    /// panel. A column that fitted the old name would truncate the new one on screen with
    /// nothing failing anywhere, so the width is asserted against the font that draws it.
    func testEveryLabelFitsTheSharedColumn() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for label in ["Trigger Level", "Darkest", "Brightest", "Snap", "Fade", "Travel"] {
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, LabeledValueSlider.labelWidth,
                                     "\(label) does not fit the label column.")
        }
    }

    /// The same argument as the label column, for the column on the other side of the
    /// bar. The readouts are drawn in SF Mono, which is wider than the SF Pro Text they
    /// used to be drawn in: "instant" grew from 41.2 points to 56.3 and went straight
    /// through a 56 point column, and "10 bulbs/s" grew from 61.5 to 80.4 and through a
    /// 74 point one. Nothing on screen would have failed, so the widths are measured
    /// here against the face that actually prints them.
    func testEveryReadoutFitsItsColumn() {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        // Every string the brightness and timing sliders can print, at both ends of
        // every range and at the value that prints the most characters.
        var shared = [LabeledValueSlider.percent(0), LabeledValueSlider.percent(1),
                      LabeledValueSlider.percent(0.35)]
        shared += [LabeledValueSlider.snapSeconds(0), LabeledValueSlider.snapSeconds(1),
                   LabeledValueSlider.snapSeconds(0.5)]
        shared += [LabeledValueSlider.fadeSeconds(0), LabeledValueSlider.fadeSeconds(1),
                   LabeledValueSlider.fadeSeconds(0.5)]
        for readout in shared {
            let width = (readout as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, LabeledValueSlider.readoutWidthDefault,
                                     "\(readout) does not fit the readout column.")
        }

        // Travel has a column of its own because it prints words as well as a number.
        for speed in [WaveEffect.travelRange.lowerBound, WaveEffect.travelRange.upperBound] {
            let readout = LabeledValueSlider.bulbsPerSecond(speed)
            let width = (readout as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, LabeledValueSlider.travelReadoutWidth,
                                     "\(readout) does not fit the Travel readout column.")
        }
    }

    /// Three faces, each with one job. A later tidy up that collapsed them back into one
    /// would leave every test green and quietly undo the pairing, so the fact that they
    /// are different fonts is asserted rather than assumed.
    func testThePanelDrawsInThreeDistinctFaces() {
        XCTAssertNotEqual(PartyStyle.presetName, PartyStyle.label,
                          "The feel names are rounded; ordinary labels are not.")
        XCTAssertNotEqual(PartyStyle.readout, PartyStyle.label,
                          "Live numbers are monospaced; ordinary labels are not.")
        XCTAssertNotEqual(PartyStyle.readout, PartyStyle.presetName)
        XCTAssertNotEqual(PartyStyle.partyTitle, PartyStyle.heroTitle,
                          "The panel title is rounded; the sheet heading is not.")
    }

    /// Feel is the only segmented control in the panel drawn in the rounded face: its
    /// segments are moods, and Effect and Bulbs are settings.
    func testOnlyTheFeelRowIsDrawnInTheRoundedFace() {
        XCTAssertEqual(FeelPicker.segmentFont, PartyStyle.presetName)

        let effect = PartySegmentedPicker(segments: [PartySegment(value: EffectKind.pulse,
                                                                 title: "Pulse")],
                                          selection: EffectKind.pulse,
                                          accessibilityLabel: "Effect",
                                          onSelect: { _ in })
        XCTAssertEqual(effect.font, PartyStyle.label)

        let bulb = PartySegmentedPicker(segments: [PartySegment(value: SpreadGroup.bass,
                                                               title: "Bass")],
                                        selection: SpreadGroup.bass,
                                        accessibilityLabel: "Bulb",
                                        onSelect: { _ in })
        XCTAssertEqual(bulb.font, PartyStyle.label)
    }

    func testEveryRescanRowIsLabelledTheWaySomeoneWouldSayIt() {
        XCTAssertEqual(SettingsView.rescanChoices.map(SettingsView.rescanLabel(for:)),
                       ["15 seconds", "30 seconds", "1 minute", "2 minutes", "5 minutes"])
    }

    func testMaxUpdatesPerSecondIsClampedToTwoThroughTen() throws {
        let model = try makeModel()
        model.setMaxUpdatesPerSecond(0)
        XCTAssertEqual(model.settings.maxUpdatesPerSecond, 2)
        model.setMaxUpdatesPerSecond(50)
        XCTAssertEqual(model.settings.maxUpdatesPerSecond, 10)
        model.setMaxUpdatesPerSecond(8)
        XCTAssertEqual(model.settings.maxUpdatesPerSecond, 8)
    }

    // MARK: The updates slider is a ceiling

    /// The slider is the most a bulb may be sent. When the room is big enough that the
    /// budget lowers it, the readout says so, so the number never lies about the room.
    func testTheUpdatesReadoutShowsTheLoweredRateWhenTheRoomIsBig() {
        XCTAssertEqual(SettingsView.updatesReadout(ceiling: 10, effective: 6, bulbCount: 10),
                       "10 (6 with 10 bulbs)")
        XCTAssertEqual(SettingsView.updatesReadout(ceiling: 10, effective: 4, bulbCount: 15),
                       "10 (4 with 15 bulbs)")
        XCTAssertEqual(SettingsView.updatesReadout(ceiling: 10, effective: 10, bulbCount: 6), "10")
        XCTAssertEqual(SettingsView.updatesReadout(ceiling: 6, effective: 6, bulbCount: 10), "6")
    }

    /// The label and the caption say what the slider is now, not what it used to be.
    func testTheUpdatesSliderIsLabeledAsACeiling() {
        XCTAssertEqual(SettingsView.updatesTitle, "Most updates per bulb, per second")
        XCTAssertEqual(SettingsView.updatesCaption,
                       "Glowbeat lowers this automatically when you have many bulbs, so the "
                        + "network keeps up.")
    }

    /// With no bulbs on the network there is nothing to share the budget between, so the
    /// rate Party Mode would use is the ceiling itself.
    func testTheEffectiveRateIsTheCeilingWithNoBulbs() throws {
        let model = try makeModel()
        model.setMaxUpdatesPerSecond(8)
        XCTAssertEqual(model.effectivePartyUpdatesPerSecond, 8)
    }

    /// A fresh install ships the ceiling at ten. Phil's stored six is his, and stays.
    func testTheShippedCeilingIsTen() {
        XCTAssertEqual(GlowbeatSettings.defaults.maxUpdatesPerSecond, 10)
    }

    /// There is one reaction control. Moving the marker moves the sensitivity with it,
    /// and there is no second setter that could put them out of step.
    func testTheMarkerIsTheOnlyReactionControl() throws {
        let model = try makeModel()
        model.setPartyGate(0.3)
        XCTAssertEqual(model.settings.partyGate, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.settings.sensitivity, 0.7, accuracy: 0.0001)

        model.setPartyGate(1)
        XCTAssertEqual(model.settings.sensitivity, 0.1, accuracy: 0.0001,
                       "At the top of the bar the room reacts only to the loud parts.")

        model.setPartyGate(0)
        XCTAssertEqual(model.settings.sensitivity, 0.95, accuracy: 0.0001,
                       "At the bottom of the bar the room reacts to everything.")
    }

    func testThePartyGateIsClampedToZeroThroughOne() throws {
        let model = try makeModel()
        XCTAssertEqual(model.settings.partyGate, 0.15, "The documented default.")
        model.setPartyGate(-3)
        XCTAssertEqual(model.settings.partyGate, 0)
        model.setPartyGate(3)
        XCTAssertEqual(model.settings.partyGate, 1)
        model.setPartyGate(0.4)
        XCTAssertEqual(model.settings.partyGate, 0.4)
    }

    /// Dragging the marker applies the gate on every frame of the drag but must not
    /// write to the store until the drag ends, or a two second drag is a few hundred
    /// writes for one decision.
    func testDraggingThePartyGateAppliesLiveAndCommitsOnlyOnRelease() throws {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        func makeModel() -> AppModel {
            AppModel(socket: socket,
                     discovery: BulbDiscovery(socket: socket, configuration: configuration),
                     controller: BulbController(socket: socket),
                     poller: StatusPoller(socket: socket, configuration: configuration),
                     frameSource: ScriptedFrameSource(),
                     tickSource: ManualTickSource(),
                     settingsStore: SettingsStore(defaults: defaults),
                     nameStore: BulbNameStore(defaults: defaults),
                     loginItems: FakeLoginItemService())
        }

        let model = makeModel()
        model.setPartyGate(0.42, persist: false)
        XCTAssertEqual(model.settings.partyGate, 0.42, "The drag has to move the marker.")
        XCTAssertEqual(makeModel().settings.partyGate, 0.15,
                       "Nothing should have reached the store mid drag.")

        model.setPartyGate(0.42)
        XCTAssertEqual(makeModel().settings.partyGate, 0.42,
                       "Releasing the marker has to commit it.")
    }

    // MARK: Popover controls

    func testThePopoverEffectAndPaletteWritesReachTheStoredSettings() throws {
        let model = try makeModel()
        model.setEffect(.wave)
        XCTAssertEqual(model.settings.effectKind, .wave)
        model.setPalette(id: Palette.ocean.id)
        XCTAssertEqual(model.settings.paletteID, Palette.ocean.id)
        // An unknown identifier falls back rather than leaving the picker with no row.
        model.setPalette(id: "does-not-exist")
        XCTAssertEqual(model.settings.paletteID, Palette.party.id)
    }

    func testEverySettingSurvivesANewModelOnTheSameStore() throws {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        func makeModel() -> AppModel {
            AppModel(socket: socket,
                     discovery: BulbDiscovery(socket: socket, configuration: configuration),
                     controller: BulbController(socket: socket),
                     poller: StatusPoller(socket: socket, configuration: configuration),
                     frameSource: ScriptedFrameSource(),
                     tickSource: ManualTickSource(),
                     settingsStore: SettingsStore(defaults: defaults),
                     nameStore: BulbNameStore(defaults: defaults),
                     loginItems: FakeLoginItemService())
        }

        let first = makeModel()
        first.setShowsMenuBarExtra(true)
        first.setRescanInterval(30)
        first.setMaxUpdatesPerSecond(4)
        first.setPartyFloor(0.25)
        first.setPartyCeiling(0.75)

        let second = makeModel()
        XCTAssertTrue(second.settings.showsMenuBarExtra)
        XCTAssertEqual(second.settings.rescanInterval, 30)
        XCTAssertEqual(second.settings.maxUpdatesPerSecond, 4)
        XCTAssertEqual(second.settings.partyFloor, 0.25, accuracy: 0.0001)
        XCTAssertEqual(second.settings.partyCeiling, 0.75, accuracy: 0.0001)
    }

    // MARK: The brightness range

    /// The same live and commit split the gate has: the room follows the drag, the store
    /// only hears about it on release.
    func testDraggingABrightnessSliderAppliesLiveAndCommitsOnlyOnRelease() throws {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        func makeModel() -> AppModel {
            AppModel(socket: socket,
                     discovery: BulbDiscovery(socket: socket, configuration: configuration),
                     controller: BulbController(socket: socket),
                     poller: StatusPoller(socket: socket, configuration: configuration),
                     frameSource: ScriptedFrameSource(),
                     tickSource: ManualTickSource(),
                     settingsStore: SettingsStore(defaults: defaults),
                     nameStore: BulbNameStore(defaults: defaults),
                     loginItems: FakeLoginItemService())
        }

        let model = makeModel()
        model.setPartyFloor(0.4, persist: false)
        XCTAssertEqual(model.settings.partyFloor, 0.4, accuracy: 0.0001)
        XCTAssertEqual(makeModel().settings.partyFloor, PartyPreset.punchy.floor,
                       accuracy: 0.0001,
                       "Nothing should have reached the store mid drag.")

        model.setPartyFloor(0.4)
        XCTAssertEqual(makeModel().settings.partyFloor, 0.4, accuracy: 0.0001)
    }

    /// The two sliders may never meet: whichever one moved keeps its value and pushes
    /// the other out of the way.
    func testTheTwoBrightnessSlidersCannotCollapseTheRange() throws {
        let model = try makeModel()
        model.setPartyCeiling(0.5)
        model.setPartyFloor(0.9)
        XCTAssertEqual(model.settings.partyFloor, 0.9, accuracy: 0.0001)
        XCTAssertEqual(model.settings.partyCeiling, 0.95, accuracy: 0.0001)

        model.setPartyCeiling(0.3)
        XCTAssertEqual(model.settings.partyCeiling, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.settings.partyFloor, 0.25, accuracy: 0.0001)

        model.setPartyFloor(2)
        XCTAssertLessThanOrEqual(model.settings.partyFloor, 1)
        XCTAssertGreaterThanOrEqual(model.settings.partyCeiling - model.settings.partyFloor,
                                    GlowbeatSettings.minimumBrightnessSpan - 0.0001)
    }

    // MARK: Feel presets

    /// Tapping a feel has to move all four Advanced values at once and keep them.
    func testApplyingAFeelWritesAllFourValuesAndKeepsThem() throws {
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: [])
        socket = LANSocket(configuration: configuration)
        try socket.start()
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        func makeModel() -> AppModel {
            AppModel(socket: socket,
                     discovery: BulbDiscovery(socket: socket, configuration: configuration),
                     controller: BulbController(socket: socket),
                     poller: StatusPoller(socket: socket, configuration: configuration),
                     frameSource: ScriptedFrameSource(),
                     tickSource: ManualTickSource(),
                     settingsStore: SettingsStore(defaults: defaults),
                     nameStore: BulbNameStore(defaults: defaults),
                     loginItems: FakeLoginItemService())
        }

        let model = makeModel()
        XCTAssertEqual(model.settings.matchingPreset, .punchy,
                       "A fresh install ships on Punchy.")

        model.applyPartyPreset(.mellow)
        XCTAssertEqual(model.settings.partyFloor, PartyPreset.mellow.floor, accuracy: 0.0001)
        XCTAssertEqual(model.settings.partyCeiling, PartyPreset.mellow.ceiling, accuracy: 0.0001)
        XCTAssertEqual(model.settings.partySnap, PartyPreset.mellow.snap, accuracy: 0.0001)
        XCTAssertEqual(model.settings.partyFade, PartyPreset.mellow.fade, accuracy: 0.0001)
        XCTAssertEqual(model.settings.matchingPreset, .mellow)

        XCTAssertEqual(makeModel().settings.matchingPreset, .mellow,
                       "A feel is one deliberate tap, so it has to reach the store.")
    }

    /// Every feel has to land exactly from every other feel. The brightness sliders push
    /// each other out of the way, so the order the four values are written in could
    /// otherwise leave a preset a hair off its own numbers and showing as Custom.
    func testEveryFeelLandsExactlyFromEveryOtherFeel() throws {
        let model = try makeModel()
        for from in PartyPreset.allCases {
            for to in PartyPreset.allCases {
                model.applyPartyPreset(from)
                model.applyPartyPreset(to)
                XCTAssertEqual(model.settings.matchingPreset, to,
                               "\(from.displayName) to \(to.displayName) did not land.")
            }
        }
    }

    /// Dragging a slider after tapping a feel drops the row to Custom, which is the one
    /// piece of behavior the picker itself has.
    func testDraggingASliderAfterAFeelDropsTheRowToCustom() throws {
        let model = try makeModel()
        model.applyPartyPreset(.punchy)
        XCTAssertEqual(model.settings.matchingPreset, .punchy)
        model.setPartyFade(PartyPreset.punchy.fade + 0.05)
        XCTAssertNil(model.settings.matchingPreset)
        model.applyPartyPreset(.punchy)
        XCTAssertEqual(model.settings.matchingPreset, .punchy,
                       "Tapping the feel again has to put it back.")
    }

    // MARK: The Advanced default row

    /// The button does the same thing whether or not anything has been saved, so the help
    /// text is the only place the app can say which default Reset means.
    func testTheResetHelpNamesWhichDefaultItMeans() {
        XCTAssertEqual(AdvancedDefaultRow.resetHelp(hasSavedDefault: false), "Back to Punchy")
        XCTAssertEqual(AdvancedDefaultRow.resetHelp(hasSavedDefault: true),
                       "Back to your saved default")
    }

    /// A second and a half: long enough to read, short enough that nobody waits for it.
    func testTheSavedConfirmationIsBrief() {
        XCTAssertEqual(AdvancedDefaultRow.confirmationDuration, .seconds(1.5))
    }

    /// The row draws in both windows and in both of its states, and so does the face the
    /// "Saved" confirmation wears, which is the one piece of chrome no button draws.
    func testTheAdvancedDefaultRowRendersInEveryState() throws {
        let model = try makeModel()
        model.setPartyAdvancedExpanded(true)

        // Dimmed: a fresh install is already on its default.
        XCTAssertFalse(model.canResetAdvanced)
        let dimmed = ImageRenderer(content: AdvancedDefaultRow(model: model).frame(width: 460))
        XCTAssertNotNil(dimmed.nsImage)

        // Live: something has moved.
        model.applyPartyPreset(.dreamy)
        XCTAssertTrue(model.canResetAdvanced)
        let live = ImageRenderer(content: AdvancedDefaultRow(model: model).frame(width: 460))
        XCTAssertNotNil(live.nsImage)

        let panel = ImageRenderer(content: PartyPanelView(model: model).frame(width: 460))
        XCTAssertNotNil(panel.nsImage)
        let settings = ImageRenderer(content: SettingsView(model: model)
            .frame(width: 460, height: 420))
        XCTAssertNotNil(settings.nsImage)

        let confirmation = ImageRenderer(content: Label("Saved", systemImage: "checkmark")
            .partyButtonFace(.prominent, fillsWidth: true))
        XCTAssertNotNil(confirmation.nsImage)
        let secondary = ImageRenderer(content: Text("Reset").partyButtonFace(.secondary))
        XCTAssertNotNil(secondary.nsImage)
    }

    /// The label drawn on an amber fill has to flip with the fill: the accent is a light
    /// amber in the dark appearance and a dark one in the light appearance, so one fixed
    /// label color would be unreadable in one of them.
    func testTheProminentButtonLabelFlipsWithTheAppearance() {
        XCTAssertNotEqual(PartyStyle.onAccent(.dark), PartyStyle.onAccent(.light))
    }

    /// One disabled amount for the whole panel, so a grayed marker and a dimmed button
    /// cannot drift apart.
    func testEveryDimmedControlFadesByTheSameAmount() {
        XCTAssertEqual(LevelMeter.disabledOpacity, PartyStyle.disabledOpacity)
    }
}

/// A flag `withObservationTracking`'s `@Sendable` handler can raise. The handler runs
/// inside the registrar's willSet, so it cannot capture a plain `var`.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
