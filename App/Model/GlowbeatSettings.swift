import Effects
import Foundation
import GoveeLAN

/// The four values behind the Advanced disclosure, as one thing: Darkest, Brightest,
/// Snap and Fade, each 0 through 1.
///
/// The same four a Feel preset sets, which is not a coincidence: a feel is a named set of
/// these and the user's saved default is an unnamed one. Trigger Level, Always react,
/// Travel and the Spread bands are deliberately not in here, for the reason `PartyPreset`
/// gives: they are set for the room and the track rather than for a feel, and a Reset
/// that quietly moved them would undo the one thing someone had just dialed in.
struct AdvancedValues: Codable, Equatable, Sendable {
    /// The Darkest slider.
    var floor: Double
    /// The Brightest slider.
    var ceiling: Double
    /// The Snap slider.
    var snap: Double
    /// The Fade slider.
    var fade: Double

    init(floor: Double, ceiling: Double, snap: Double, fade: Double) {
        let range = GlowbeatSettings.brightnessRange(settingFloor: floor, ceiling: ceiling)
        self.floor = range.floor
        self.ceiling = range.ceiling
        self.snap = min(1, max(0, snap))
        self.fade = min(1, max(0, fade))
    }

    /// A feel, as the four numbers it is made of.
    init(preset: PartyPreset) {
        self.init(floor: preset.floor,
                  ceiling: preset.ceiling,
                  snap: preset.snap,
                  fade: preset.fade)
    }

    /// Whether these four are, for the user's purposes, the same four as those.
    ///
    /// The tolerance is `PartyPreset.tolerance`, the one the Feel row recognizes a preset
    /// by, because it is the same question asked of the same four doubles: a value that
    /// has been through the timing curves and back off disk has to still count as the
    /// value that was saved. This is what dims the Reset and Save buttons.
    func matches(_ other: AdvancedValues) -> Bool {
        abs(floor - other.floor) <= PartyPreset.tolerance
            && abs(ceiling - other.ceiling) <= PartyPreset.tolerance
            && abs(snap - other.snap) <= PartyPreset.tolerance
            && abs(fade - other.fade) <= PartyPreset.tolerance
    }
}

/// Everything the user can change that outlives a launch.
struct GlowbeatSettings: Equatable, Sendable {
    var showsMenuBarExtra: Bool
    var launchesAtLogin: Bool
    /// Seconds between automatic rescans, 15 through 300.
    var rescanInterval: TimeInterval
    /// Party Mode sends per bulb per second, 2 through 10.
    var maxUpdatesPerSecond: Int
    var hasCompletedFirstRun: Bool
    var effectKindID: String
    var paletteID: String
    /// 0 through 1. The one reaction control: the level below which Party Mode leaves
    /// every bulb at its darkest, shown as a draggable marker on the Trigger Level bar,
    /// and the value the beat detector's sensitivity is derived from.
    var partyGate: Double
    /// Whether Party Mode ignores the marker and reacts to every sound. The marker keeps
    /// the value the user left it at: this only stops it being used, so unticking the box
    /// puts the room back exactly where it was.
    var alwaysReacts: Bool
    /// 0 through 1. How bright a bulb sits when nothing is happening, the Darkest slider.
    /// Ships at Punchy's 10 percent.
    var partyFloor: Double
    /// 0 through 1. How bright a bulb goes on a full hit, the Brightest slider. Always at
    /// least `minimumBrightnessSpan` above the floor. Ships at Punchy's 100 percent.
    var partyCeiling: Double
    /// 0 through 1. How fast the lights jump on a hit, the Snap slider. 1 is instant,
    /// which is where Punchy puts it, so out of the box a hit lands inside one tick.
    var partySnap: Double
    /// 0 through 1. How slowly the lights settle after a hit, the Fade slider. Ships at
    /// Punchy's 0.3 s settle.
    var partyFade: Double
    /// How fast Wave's colors travel from bulb to bulb, in bulbs per second, 1 through 15.
    /// Wave is the only effect that has a direction, so this is the per effect setting it
    /// gets, and it lives on the Party panel rather than in Settings.
    var waveTravelSpeed: Double
    /// Which part of the music each bulb follows in Spread, as bulb id to
    /// `SpreadGroup.rawValue`.
    ///
    /// Keyed on the bulb id rather than on a position, so a band belongs to the bulb and
    /// survives a reorder. A bulb with no entry takes the round robin fallback for its
    /// place in the list, which is what Spread did before the choice existed, so an empty
    /// map is the old behavior exactly. Raw values rather than `SpreadGroup` so the whole
    /// thing is a plist dictionary with nothing to encode.
    var spreadAssignments: [String: Int]
    /// Confetti: every bulb gets its own color from the palette, never the same as its
    /// neighbors'. Works with every effect. Off on a fresh install.
    var partyConfetti: Bool
    /// The scene the picker shows. Remembered across launches; never started by itself.
    var sceneKindID: String
    /// 0.25 through 4.
    var sceneSpeed: Double
    /// Static's single color mode: one palette color for the whole room. Remembered for
    /// every scene, applied only by the one that has such a mode.
    var sceneSingleColor: Bool
    /// Which still color the Colors pane is ringing, or nil until anyone has picked one.
    ///
    /// The selection, which is not the same thing as what the room is wearing: a still
    /// color is one shot, so the app cannot know whether the bulbs are still on it after
    /// a relaunch. `AppModel.appliedStillColor` is the live half and is deliberately not
    /// stored.
    var stillColorID: String?
    /// 0.01 through 1. The brightness a still color is applied at, which is also the
    /// brightness the Colors pane's own slider sits at.
    var stillBrightness: Double
    /// Whether the window's Scenes section is open. Collapsing a section is how the window
    /// is made to fit a short display, so which sections are open outlives a launch.
    var showsScenesSection: Bool
    /// Whether the window's Party Mode section is open.
    var showsPartySection: Bool
    /// Which pane the window is showing. Bulbs on a fresh install, then whatever it was
    /// left on: coming back to a window on a different screen than the one you left is
    /// disorienting in a way that no amount of polish makes up for.
    var selectedPaneID: String
    /// Whether the Party panel's Advanced group is open. Darkest, Brightest, Snap and
    /// Fade live in there. They started folded away, because the old one column window
    /// read as a wall of sliders with all five on show. The Party pane is two columns
    /// now and there is room for them, so they start open; someone who folds them away
    /// still finds them folded away next launch.
    var showsPartyAdvanced: Bool
    /// The four Advanced values the user asked to keep, or nil until anyone has asked.
    ///
    /// Nil is the shipped state and is not the same thing as Punchy: it means nobody has
    /// chosen a default yet, so Reset falls back to what a fresh install runs on. Storing
    /// Punchy here on first launch would be a lie the moment the shipped feel changed.
    var savedAdvancedDefault: AdvancedValues?

    /// The white the room sits at: Daylight, Night or Auto. Stored as a raw value so the
    /// whole settings object stays a plist with nothing to encode, the way the effect and
    /// the scene are.
    var lightModeID: String
    /// Minutes, 0 through 120. How long Auto takes to shift between Daylight and Night.
    ///
    /// Glowbeat's own, not the Mac's. Night Shift fades the screen over exactly 120
    /// seconds, which is far too fast for a room light, so Auto ignores that fade and
    /// runs this ramp from the moment Night Shift's own flag flips.
    var shiftLengthMinutes: Int
    /// The wake and sleep timers.
    var schedule: ScheduleSettings

    /// What a fresh install runs on.
    ///
    /// The four Party Mode feel values are Punchy's own, taken from the preset rather
    /// than retyped, so `matchingPreset` reads `.punchy` out of the box and the Feel row
    /// says so. Phil's call on 2026-09-14: "ship on Punchy by default." The Effects
    /// package keeps `EffectTiming.standard` as its own default for an effect built
    /// without the engine; that is a separate number and no longer the app's.
    static let defaults = GlowbeatSettings(showsMenuBarExtra: false,
                                           launchesAtLogin: false,
                                           rescanInterval: 60,
                                           maxUpdatesPerSecond: StreamRateLimiter.defaultSendsPerSecond,
                                           hasCompletedFirstRun: false,
                                           effectKindID: EffectKind.pulse.rawValue,
                                           paletteID: Palette.party.id,
                                           partyGate: 0.15,
                                           alwaysReacts: false,
                                           partyFloor: PartyPreset.punchy.floor,
                                           partyCeiling: PartyPreset.punchy.ceiling,
                                           partySnap: PartyPreset.punchy.snap,
                                           partyFade: PartyPreset.punchy.fade,
                                           waveTravelSpeed: WaveEffect.defaultTravelSpeed,
                                           spreadAssignments: [:],
                                           partyConfetti: false,
                                           sceneKindID: SceneKind.breathe.rawValue,
                                           sceneSpeed: SceneKind.defaultSpeed,
                                           sceneSingleColor: false,
                                           stillColorID: nil,
                                           stillBrightness: StillColor.defaultBrightness,
                                           showsScenesSection: true,
                                           showsPartySection: true,
                                           selectedPaneID: SidebarPane.bulbs.rawValue,
                                           showsPartyAdvanced: true,
                                           savedAdvancedDefault: nil,
                                           lightModeID: LightMode.daylight.rawValue,
                                           shiftLengthMinutes: defaultShiftLengthMinutes,
                                           schedule: .defaults)

    /// The beat sensitivity the gate implies. Reading it rather than storing it is what
    /// keeps the single control single: there is no second value that can drift away from
    /// the marker, and nothing to keep in step when someone drags it.
    var sensitivity: Double {
        Self.derivedSensitivity(forGate: partyGate)
    }

    /// `1 - gate`, held inside 0.1 through 0.95.
    ///
    /// A marker at the bottom means "react to everything", which is a detector that fires
    /// readily. A marker at the top means "only the loud parts", which is a detector that
    /// waits for a real hit. The clamps keep both ends usable: a detector at 0 never fires
    /// at all and one at 1 fires on room tone.
    ///
    /// The sensitivity this returns lands on `BeatDetector.thresholdMultiplier`, which
    /// since 2026-09-14 runs a straight line from 1.65 times the rolling mean down to
    /// 1.2 times it. Replaying real tracks showed everything usable lives in that window:
    /// a dense hip hop mix dropped from 3.5 low band beats a second at 1.35x to 0.6 at
    /// 1.65x and 0.04 at 2x, while below 1.2x a dance track fired eight a second and lit
    /// the room solid. So the marker now stays inside the window at every position: at
    /// 70 percent it asks for about 1.52x, where a kick still counts.
    static func derivedSensitivity(forGate gate: Double) -> Double {
        let threshold = min(1, max(0, gate))
        return min(0.95, max(0.1, 1 - threshold))
    }

    /// The beat sensitivity Always react pins the detector to, which is the middle of the
    /// same scale `derivedSensitivity(forGate:)` runs on: 1.425 times the rolling mean.
    ///
    /// The marker is not only the level the room has to clear, it also drives the
    /// detector, so a grayed marker cannot be allowed to keep driving it. Following the
    /// marker would mean a marker parked at the bottom silently asked for the loosest
    /// detector there is and the room sat lit instead of pulsing; ignoring it and taking
    /// the bottom of the scale would do the same. The middle keeps the room pulsing
    /// whatever the marker happens to say underneath the checkbox.
    static let alwaysReactsSensitivity: Double = 0.5

    /// The feel the four Advanced values are sitting on, or nil for Custom.
    ///
    /// Derived rather than stored, for the reason `sensitivity` is: a stored name could
    /// drift away from the numbers underneath it, and then the row would claim a feel the
    /// room is not running. Dragging any of the four sliders drops this to nil by itself,
    /// which is the whole of "the picker goes to Custom when you touch a slider".
    var matchingPreset: PartyPreset? {
        PartyPreset.allCases.first { preset in
            preset.matches(floor: partyFloor,
                           ceiling: partyCeiling,
                           snap: partySnap,
                           fade: partyFade)
        }
    }

    /// The four Advanced values as they stand right now.
    var advancedValues: AdvancedValues {
        AdvancedValues(floor: partyFloor,
                       ceiling: partyCeiling,
                       snap: partySnap,
                       fade: partyFade)
    }

    /// Where Reset goes: the user's saved default, or Punchy when there is not one.
    ///
    /// Punchy is the fallback rather than a hard coded copy of four numbers, so "back to
    /// how it shipped" stays true if the shipped feel is ever changed again.
    var effectiveAdvancedDefault: AdvancedValues {
        savedAdvancedDefault ?? AdvancedValues(preset: .punchy)
    }

    var effectKind: EffectKind {
        get { EffectKind(rawValue: effectKindID) ?? .pulse }
        set { effectKindID = newValue.rawValue }
    }

    var palette: Palette {
        Palette.palette(withID: paletteID)
    }

    var selectedPane: SidebarPane {
        get { SidebarPane(rawValue: selectedPaneID) ?? .bulbs }
        set { selectedPaneID = newValue.rawValue }
    }

    var sceneKind: SceneKind {
        get { SceneKind(rawValue: sceneKindID) ?? .breathe }
        set { sceneKindID = newValue.rawValue }
    }

    /// The picked color itself, or nil when nobody has picked one and when a stored id
    /// names a color this build's catalog does not have.
    var stillColor: StillColor? {
        StillColor.color(withID: stillColorID)
    }

    var lightMode: LightMode {
        get { LightMode(rawValue: lightModeID) ?? .daylight }
        set { lightModeID = newValue.rawValue }
    }

    var shiftLength: TimeInterval {
        TimeInterval(shiftLengthMinutes) * 60
    }

    /// Half an hour. Long enough that a room does not visibly step between whites, short
    /// enough that the room has finished changing well before anyone wonders whether it
    /// is going to.
    static let defaultShiftLengthMinutes = 30
    static let maximumShiftLengthMinutes = 120

    static func clampedShiftLengthMinutes(_ value: Int) -> Int {
        min(maximumShiftLengthMinutes, max(0, value))
    }

    /// The supported ranges live with the code that enforces them, so Settings, the app
    /// model and the store all clamp to the same numbers rather than to three copies of
    /// them that can drift apart.
    static func clampedRescanInterval(_ seconds: TimeInterval) -> TimeInterval {
        min(BulbDiscovery.maximumRescanInterval,
            max(BulbDiscovery.minimumRescanInterval, seconds))
    }

    static func clampedUpdatesPerSecond(_ value: Int) -> Int {
        StreamRateLimiter.clampSendsPerSecond(value)
    }

    /// How close the Darkest and Brightest sliders may come to each other. With no gap at
    /// all the room would stop reacting entirely, which reads as the app being broken
    /// rather than as a choice the user made.
    static let minimumBrightnessSpan: Double = 0.05

    /// The pair with the floor as the user just set it: the ceiling is pushed up out of
    /// the way if it would come closer than the minimum span. Also what a stored pair is
    /// read back through, so a hand edited plist cannot invert the range.
    static func brightnessRange(settingFloor floor: Double,
                                ceiling: Double) -> (floor: Double, ceiling: Double) {
        let low = min(1 - minimumBrightnessSpan, max(0, floor))
        let high = min(1, max(low + minimumBrightnessSpan, ceiling))
        return (low, high)
    }

    /// The pair with the ceiling as the user just set it: the floor is pushed down out of
    /// the way instead.
    static func brightnessRange(settingCeiling ceiling: Double,
                                floor: Double) -> (floor: Double, ceiling: Double) {
        let high = min(1, max(minimumBrightnessSpan, ceiling))
        let low = max(0, min(high - minimumBrightnessSpan, floor))
        return (low, high)
    }
}

/// Reads and writes `GlowbeatSettings` in `UserDefaults`, clamping every value on the
/// way in so a hand edited plist cannot put the app into a bad state.
final class SettingsStore {

    private enum Key {
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let launchesAtLogin = "launchesAtLogin"
        static let rescanInterval = "rescanInterval"
        static let maxUpdatesPerSecond = "maxUpdatesPerSecond"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let effectKindID = "effectKindID"
        static let paletteID = "paletteID"
        static let sensitivity = "sensitivity"
        static let partyGate = "partyGate"
        static let alwaysReacts = "alwaysReacts"
        static let partyFloor = "partyFloor"
        static let partyCeiling = "partyCeiling"
        static let partySnap = "partySnap"
        static let partyFade = "partyFade"
        static let waveTravelSpeed = "waveTravelSpeed"
        static let spreadAssignments = "spreadAssignments"
        static let partyConfetti = "partyConfetti"
        static let sceneKindID = "sceneKindID"
        static let sceneSpeed = "sceneSpeed"
        static let sceneSingleColor = "sceneSingleColor"
        static let stillColorID = "stillColorID"
        static let stillBrightness = "stillBrightness"
        static let showsScenesSection = "showsScenesSection"
        static let showsPartySection = "showsPartySection"
        static let selectedPaneID = "selectedPaneID"
        static let showsPartyAdvanced = "showsPartyAdvanced"
        static let savedAdvancedDefault = "savedAdvancedDefault"
        static let lightModeID = "lightModeID"
        static let shiftLengthMinutes = "shiftLengthMinutes"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleWakeHour = "scheduleWakeHour"
        static let scheduleWakeMinute = "scheduleWakeMinute"
        static let scheduleSleepHour = "scheduleSleepHour"
        static let scheduleSleepMinute = "scheduleSleepMinute"
        static let scheduleWakeRampMinutes = "scheduleWakeRampMinutes"
        static let scheduleSleepRampMinutes = "scheduleSleepRampMinutes"
        static let scheduleWakeBrightness = "scheduleWakeBrightness"
        /// Not a setting: the last moment the schedule reconciled itself against the
        /// clock. It lives in the store rather than in `GlowbeatSettings` because it is
        /// written every thirty seconds and `settings` is one observed property, so
        /// putting it there would re-run every view in the app twice a minute.
        static let scheduleLastReconciled = "scheduleLastReconciled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GlowbeatSettings {
        var settings = GlowbeatSettings.defaults
        settings.showsMenuBarExtra = defaults.bool(forKey: Key.showsMenuBarExtra)
        settings.launchesAtLogin = defaults.bool(forKey: Key.launchesAtLogin)
        settings.hasCompletedFirstRun = defaults.bool(forKey: Key.hasCompletedFirstRun)

        if defaults.object(forKey: Key.rescanInterval) != nil {
            settings.rescanInterval = GlowbeatSettings.clampedRescanInterval(
                defaults.double(forKey: Key.rescanInterval))
        }
        if defaults.object(forKey: Key.maxUpdatesPerSecond) != nil {
            settings.maxUpdatesPerSecond = GlowbeatSettings.clampedUpdatesPerSecond(
                defaults.integer(forKey: Key.maxUpdatesPerSecond))
        }
        if defaults.object(forKey: Key.partyGate) != nil {
            settings.partyGate = min(1, max(0, defaults.double(forKey: Key.partyGate)))
        }
        // Off on a fresh install, so an empty store means false and a plain read is
        // enough.
        settings.alwaysReacts = defaults.bool(forKey: Key.alwaysReacts)
        if defaults.object(forKey: Key.partyFloor) != nil {
            settings.partyFloor = defaults.double(forKey: Key.partyFloor)
        }
        if defaults.object(forKey: Key.partyCeiling) != nil {
            settings.partyCeiling = defaults.double(forKey: Key.partyCeiling)
        }
        let range = GlowbeatSettings.brightnessRange(settingFloor: settings.partyFloor,
                                                    ceiling: settings.partyCeiling)
        settings.partyFloor = range.floor
        settings.partyCeiling = range.ceiling
        if defaults.object(forKey: Key.partySnap) != nil {
            settings.partySnap = min(1, max(0, defaults.double(forKey: Key.partySnap)))
        }
        if defaults.object(forKey: Key.partyFade) != nil {
            settings.partyFade = min(1, max(0, defaults.double(forKey: Key.partyFade)))
        }
        if defaults.object(forKey: Key.waveTravelSpeed) != nil {
            settings.waveTravelSpeed = WaveEffect.clampedTravelSpeed(
                defaults.double(forKey: Key.waveTravelSpeed))
        }
        // Anything that is not a group this build knows is dropped rather than carried:
        // a hand edited plist, or a group that stops existing in a later version, must
        // not put a bulb on a band the effect has never heard of.
        if let stored = defaults.dictionary(forKey: Key.spreadAssignments) {
            settings.spreadAssignments = stored.compactMapValues { value in
                guard let raw = value as? Int, SpreadGroup(rawValue: raw) != nil else {
                    return nil
                }
                return raw
            }
        }
        // Off on a fresh install, so an empty store means false and a plain read is
        // enough.
        settings.partyConfetti = defaults.bool(forKey: Key.partyConfetti)
        if defaults.object(forKey: Key.sceneSpeed) != nil {
            settings.sceneSpeed = SceneKind.clampedSpeed(defaults.double(forKey: Key.sceneSpeed))
        }
        settings.sceneSingleColor = defaults.bool(forKey: Key.sceneSingleColor)
        // A color id from a hand edited plist, or from a build whose catalog had one this
        // build's does not, is dropped rather than kept: the pane would otherwise ring a
        // swatch that is not on screen.
        if let rawColor = defaults.string(forKey: Key.stillColorID),
           StillColor.color(withID: rawColor) != nil {
            settings.stillColorID = rawColor
        }
        if defaults.object(forKey: Key.stillBrightness) != nil {
            settings.stillBrightness = StillColor.clampedBrightness(
                defaults.double(forKey: Key.stillBrightness))
        }
        // Both sections start open, so an empty store means true rather than false.
        if defaults.object(forKey: Key.showsScenesSection) != nil {
            settings.showsScenesSection = defaults.bool(forKey: Key.showsScenesSection)
        }
        if defaults.object(forKey: Key.showsPartySection) != nil {
            settings.showsPartySection = defaults.bool(forKey: Key.showsPartySection)
        }
        // Advanced starts open now, so an empty store means true rather than false and a
        // plain read would quietly fold it away on every fresh install.
        if defaults.object(forKey: Key.showsPartyAdvanced) != nil {
            settings.showsPartyAdvanced = defaults.bool(forKey: Key.showsPartyAdvanced)
        }
        // A pane id this build does not know, from a hand edited plist or a later
        // version, must not leave the window showing nothing.
        if let rawPane = defaults.string(forKey: Key.selectedPaneID),
           SidebarPane(rawValue: rawPane) != nil {
            settings.selectedPaneID = rawPane
        }
        // Absent until the user saves one, and dropped rather than repaired if it is not
        // all four numbers: half a default would reset the room somewhere nobody chose.
        // The values themselves are clamped by `AdvancedValues` on the way in, the way
        // every other stored number is.
        settings.savedAdvancedDefault = Self.advancedValues(
            fromStored: defaults.dictionary(forKey: Key.savedAdvancedDefault))
        if let rawScene = defaults.string(forKey: Key.sceneKindID),
           SceneKind(rawValue: rawScene) != nil {
            settings.sceneKindID = rawScene
        }
        if let rawMode = defaults.string(forKey: Key.lightModeID),
           LightMode(rawValue: rawMode) != nil {
            settings.lightModeID = rawMode
        }
        if defaults.object(forKey: Key.shiftLengthMinutes) != nil {
            settings.shiftLengthMinutes = GlowbeatSettings.clampedShiftLengthMinutes(
                defaults.integer(forKey: Key.shiftLengthMinutes))
        }
        settings.schedule = loadSchedule()
        if let rawEffect = defaults.string(forKey: Key.effectKindID),
           EffectKind(rawValue: rawEffect) != nil {
            settings.effectKindID = rawEffect
        }
        if let rawPalette = defaults.string(forKey: Key.paletteID),
           Palette.all.contains(where: { $0.id == rawPalette }) {
            settings.paletteID = rawPalette
        }
        return settings
    }

    func save(_ settings: GlowbeatSettings) {
        defaults.set(settings.showsMenuBarExtra, forKey: Key.showsMenuBarExtra)
        defaults.set(settings.launchesAtLogin, forKey: Key.launchesAtLogin)
        defaults.set(GlowbeatSettings.clampedRescanInterval(settings.rescanInterval),
                     forKey: Key.rescanInterval)
        defaults.set(GlowbeatSettings.clampedUpdatesPerSecond(settings.maxUpdatesPerSecond),
                     forKey: Key.maxUpdatesPerSecond)
        defaults.set(settings.hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun)
        defaults.set(settings.effectKindID, forKey: Key.effectKindID)
        defaults.set(settings.paletteID, forKey: Key.paletteID)
        // Written but never read back: the sensitivity is derived from the gate now. The
        // key stays so an older build installed over this one still finds a sane value.
        defaults.set(settings.sensitivity, forKey: Key.sensitivity)
        defaults.set(min(1, max(0, settings.partyGate)), forKey: Key.partyGate)
        defaults.set(settings.alwaysReacts, forKey: Key.alwaysReacts)
        let range = GlowbeatSettings.brightnessRange(settingFloor: settings.partyFloor,
                                                     ceiling: settings.partyCeiling)
        defaults.set(range.floor, forKey: Key.partyFloor)
        defaults.set(range.ceiling, forKey: Key.partyCeiling)
        defaults.set(min(1, max(0, settings.partySnap)), forKey: Key.partySnap)
        defaults.set(min(1, max(0, settings.partyFade)), forKey: Key.partyFade)
        defaults.set(WaveEffect.clampedTravelSpeed(settings.waveTravelSpeed),
                     forKey: Key.waveTravelSpeed)
        defaults.set(settings.spreadAssignments, forKey: Key.spreadAssignments)
        defaults.set(settings.partyConfetti, forKey: Key.partyConfetti)
        defaults.set(settings.sceneKindID, forKey: Key.sceneKindID)
        defaults.set(SceneKind.clampedSpeed(settings.sceneSpeed), forKey: Key.sceneSpeed)
        defaults.set(settings.sceneSingleColor, forKey: Key.sceneSingleColor)
        if let stillColorID = settings.stillColorID {
            defaults.set(stillColorID, forKey: Key.stillColorID)
        } else {
            // Removed rather than written as an empty string, so "nobody has picked one"
            // survives a save and a cleared selection really is cleared.
            defaults.removeObject(forKey: Key.stillColorID)
        }
        defaults.set(StillColor.clampedBrightness(settings.stillBrightness),
                     forKey: Key.stillBrightness)
        defaults.set(settings.showsScenesSection, forKey: Key.showsScenesSection)
        defaults.set(settings.showsPartySection, forKey: Key.showsPartySection)
        defaults.set(settings.showsPartyAdvanced, forKey: Key.showsPartyAdvanced)
        defaults.set(settings.selectedPane.rawValue, forKey: Key.selectedPaneID)
        defaults.set(settings.lightMode.rawValue, forKey: Key.lightModeID)
        defaults.set(GlowbeatSettings.clampedShiftLengthMinutes(settings.shiftLengthMinutes),
                     forKey: Key.shiftLengthMinutes)
        save(schedule: settings.schedule)
        if let saved = settings.savedAdvancedDefault {
            defaults.set(Self.stored(saved), forKey: Key.savedAdvancedDefault)
        } else {
            // Removed rather than written as an empty dictionary, so "no default yet"
            // survives being saved and a cleared default really is cleared.
            defaults.removeObject(forKey: Key.savedAdvancedDefault)
        }
    }

    // MARK: The schedule

    private func loadSchedule() -> ScheduleSettings {
        var schedule = ScheduleSettings.defaults
        // Off on a fresh install, so an empty store means false and a plain read is
        // enough.
        schedule.isEnabled = defaults.bool(forKey: Key.scheduleEnabled)
        if defaults.object(forKey: Key.scheduleWakeHour) != nil {
            schedule.wakeTime = TimeOfDay(hour: defaults.integer(forKey: Key.scheduleWakeHour),
                                          minute: defaults.integer(forKey: Key.scheduleWakeMinute))
        }
        if defaults.object(forKey: Key.scheduleSleepHour) != nil {
            schedule.sleepTime = TimeOfDay(hour: defaults.integer(forKey: Key.scheduleSleepHour),
                                           minute: defaults.integer(forKey: Key.scheduleSleepMinute))
        }
        if defaults.object(forKey: Key.scheduleWakeRampMinutes) != nil {
            schedule.wakeRampMinutes = ScheduleSettings.clampedRampMinutes(
                defaults.integer(forKey: Key.scheduleWakeRampMinutes))
        }
        if defaults.object(forKey: Key.scheduleSleepRampMinutes) != nil {
            schedule.sleepRampMinutes = ScheduleSettings.clampedRampMinutes(
                defaults.integer(forKey: Key.scheduleSleepRampMinutes))
        }
        if defaults.object(forKey: Key.scheduleWakeBrightness) != nil {
            schedule.wakeBrightness = ScheduleSettings.clampedWakeBrightness(
                defaults.integer(forKey: Key.scheduleWakeBrightness))
        }
        return schedule
    }

    private func save(schedule: ScheduleSettings) {
        defaults.set(schedule.isEnabled, forKey: Key.scheduleEnabled)
        defaults.set(schedule.wakeTime.hour, forKey: Key.scheduleWakeHour)
        defaults.set(schedule.wakeTime.minute, forKey: Key.scheduleWakeMinute)
        defaults.set(schedule.sleepTime.hour, forKey: Key.scheduleSleepHour)
        defaults.set(schedule.sleepTime.minute, forKey: Key.scheduleSleepMinute)
        defaults.set(ScheduleSettings.clampedRampMinutes(schedule.wakeRampMinutes),
                     forKey: Key.scheduleWakeRampMinutes)
        defaults.set(ScheduleSettings.clampedRampMinutes(schedule.sleepRampMinutes),
                     forKey: Key.scheduleSleepRampMinutes)
        defaults.set(ScheduleSettings.clampedWakeBrightness(schedule.wakeBrightness),
                     forKey: Key.scheduleWakeBrightness)
    }

    /// The last moment the schedule looked at the clock, or nil before it ever has.
    ///
    /// This is what makes a missed timer catchable: any wake or sleep time that falls
    /// between this and now is a timer that should have fired while nobody was looking.
    /// Nil means there is no window yet, so nothing is replayed on a first launch.
    func loadLastReconciled() -> Date? {
        defaults.object(forKey: Key.scheduleLastReconciled) as? Date
    }

    func saveLastReconciled(_ date: Date) {
        defaults.set(date, forKey: Key.scheduleLastReconciled)
    }

    func clearLastReconciled() {
        defaults.removeObject(forKey: Key.scheduleLastReconciled)
    }

    /// A plist dictionary of four doubles rather than encoded `Data`, for the reason
    /// `spreadAssignments` is a plain dictionary: `defaults read com.philwoolley.glowbeat`
    /// stays legible, and a value someone has edited by hand can be clamped rather than
    /// only rejected.
    private static let storedKeys = (floor: "floor", ceiling: "ceiling",
                                     snap: "snap", fade: "fade")

    private static func stored(_ values: AdvancedValues) -> [String: Double] {
        [storedKeys.floor: values.floor,
         storedKeys.ceiling: values.ceiling,
         storedKeys.snap: values.snap,
         storedKeys.fade: values.fade]
    }

    private static func advancedValues(fromStored stored: [String: Any]?) -> AdvancedValues? {
        guard let stored,
              let floor = stored[storedKeys.floor] as? Double,
              let ceiling = stored[storedKeys.ceiling] as? Double,
              let snap = stored[storedKeys.snap] as? Double,
              let fade = stored[storedKeys.fade] as? Double else { return nil }
        return AdvancedValues(floor: floor, ceiling: ceiling, snap: snap, fade: fade)
    }
}
