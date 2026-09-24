import XCTest
import Effects
import GoveeLAN
@testable import Glowbeat

final class GlowbeatSettingsTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let name = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAnEmptyStoreReturnsTheDocumentedDefaults() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        let settings = store.load()
        XCTAssertFalse(settings.showsMenuBarExtra)
        XCTAssertFalse(settings.launchesAtLogin)
        XCTAssertEqual(settings.rescanInterval, 60)
        XCTAssertEqual(settings.maxUpdatesPerSecond, 10)
        XCTAssertEqual(settings.maxUpdatesPerSecond, StreamRateLimiter.defaultSendsPerSecond)
        XCTAssertFalse(settings.hasCompletedFirstRun)
        XCTAssertEqual(settings.effectKind, .pulse)
        XCTAssertEqual(settings.palette.id, "party")
        XCTAssertEqual(settings.partyGate, 0.15)
        XCTAssertEqual(settings.sensitivity, 0.85, accuracy: 0.0001,
                       "The sensitivity is whatever the default gate implies.")
        XCTAssertEqual(settings.partyFloor, PartyPreset.punchy.floor, accuracy: 0.0001)
        XCTAssertEqual(settings.partyCeiling, PartyPreset.punchy.ceiling, accuracy: 0.0001)
        XCTAssertEqual(settings.matchingPreset, .punchy,
                       "Glowbeat ships on Punchy, so a fresh install reads Punchy.")
    }

    func testSettingsRoundTrip() throws {
        let defaults = try makeDefaults()
        var settings = SettingsStore(defaults: defaults).load()
        settings.showsMenuBarExtra = true
        settings.launchesAtLogin = true
        settings.rescanInterval = 120
        settings.maxUpdatesPerSecond = 4
        settings.hasCompletedFirstRun = true
        settings.effectKind = .wave
        settings.paletteID = "ocean"
        settings.partyGate = 0.4
        settings.partyFloor = 0.25
        settings.partyCeiling = 0.75
        SettingsStore(defaults: defaults).save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(reloaded, settings)
        XCTAssertEqual(reloaded.palette.id, "ocean")
    }

    func testOutOfRangeValuesAreClampedOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(99, forKey: "maxUpdatesPerSecond")
        defaults.set(1.0, forKey: "rescanInterval")
        defaults.set(-1.0, forKey: "partyGate")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.maxUpdatesPerSecond, 10)
        XCTAssertEqual(settings.rescanInterval, 15)
        XCTAssertEqual(settings.partyGate, 0)
    }

    func testAGateAboveOneIsClampedOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(9.0, forKey: "partyGate")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().partyGate, 1)
    }

    func testAnUnknownEffectOrPaletteFallsBackToTheDefault() throws {
        let defaults = try makeDefaults()
        defaults.set("does-not-exist", forKey: "effectKindID")
        defaults.set("does-not-exist", forKey: "paletteID")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.effectKind, .pulse)
        XCTAssertEqual(settings.palette.id, "party")
    }

    /// The clamps are the package's own supported ranges, not numbers retyped here. A
    /// change to either range has to move these values with it.
    func testTheClampsComeFromThePackagesThatEnforceThem() {
        XCTAssertEqual(GlowbeatSettings.clampedRescanInterval(1),
                       BulbDiscovery.minimumRescanInterval)
        XCTAssertEqual(GlowbeatSettings.clampedRescanInterval(9_999),
                       BulbDiscovery.maximumRescanInterval)
        XCTAssertEqual(GlowbeatSettings.clampedUpdatesPerSecond(0),
                       StreamRateLimiter.supportedSendsPerSecond.lowerBound)
        XCTAssertEqual(GlowbeatSettings.clampedUpdatesPerSecond(99),
                       StreamRateLimiter.supportedSendsPerSecond.upperBound)
    }

    /// The store clamps on the way in and on the way out, so a hand edited plist cannot
    /// put the app outside what the packages support.
    func testAHandEditedPlistIsClampedOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(2, forKey: "rescanInterval")
        defaults.set(99, forKey: "maxUpdatesPerSecond")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.rescanInterval, BulbDiscovery.minimumRescanInterval)
        XCTAssertEqual(settings.maxUpdatesPerSecond,
                       StreamRateLimiter.supportedSendsPerSecond.upperBound)
    }

    // MARK: The Party Mode brightness range

    /// An inverted or collapsed pair from a hand edited plist must come back as a usable
    /// range rather than as a room that never reacts.
    func testAnInvertedBrightnessRangeIsOpenedUpOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(0.9, forKey: "partyFloor")
        defaults.set(0.2, forKey: "partyCeiling")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.partyFloor, 0.9, accuracy: 0.0001)
        XCTAssertEqual(settings.partyCeiling, 0.95, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(settings.partyCeiling - settings.partyFloor,
                                    GlowbeatSettings.minimumBrightnessSpan - 0.0001)
    }

    func testBrightnessValuesOutsideZeroThroughOneAreClampedOnLoad() throws {
        let defaults = try makeDefaults()
        defaults.set(-3.0, forKey: "partyFloor")
        defaults.set(9.0, forKey: "partyCeiling")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.partyFloor, 0)
        XCTAssertEqual(settings.partyCeiling, 1)
    }

    /// Whichever slider the user moved is the one that keeps the value it was given.
    func testTheSliderThatMovedWinsTheClamp() {
        let raisedFloor = GlowbeatSettings.brightnessRange(settingFloor: 0.8, ceiling: 0.5)
        XCTAssertEqual(raisedFloor.floor, 0.8, accuracy: 0.0001)
        XCTAssertEqual(raisedFloor.ceiling, 0.85, accuracy: 0.0001)

        let loweredCeiling = GlowbeatSettings.brightnessRange(settingCeiling: 0.3, floor: 0.6)
        XCTAssertEqual(loweredCeiling.ceiling, 0.3, accuracy: 0.0001)
        XCTAssertEqual(loweredCeiling.floor, 0.25, accuracy: 0.0001)
    }

    /// The floor can never be pushed so high that there is no room left above it.
    func testAFloorAtTheTopLeavesRoomForTheCeiling() {
        let range = GlowbeatSettings.brightnessRange(settingFloor: 1, ceiling: 1)
        XCTAssertEqual(range.floor, 1 - GlowbeatSettings.minimumBrightnessSpan, accuracy: 0.0001)
        XCTAssertEqual(range.ceiling, 1, accuracy: 0.0001)

        let bottom = GlowbeatSettings.brightnessRange(settingCeiling: 0, floor: 0)
        XCTAssertEqual(bottom.ceiling, GlowbeatSettings.minimumBrightnessSpan, accuracy: 0.0001)
        XCTAssertEqual(bottom.floor, 0, accuracy: 0.0001)
    }

    // MARK: The one reaction control

    /// The marker is the only reaction control there is, so the sensitivity follows it
    /// rather than being stored beside it.
    func testTheSensitivityIsDerivedFromTheGate() {
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0.15), 0.85, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0.3), 0.7, accuracy: 0.0001)
    }

    /// Both ends stay usable: a detector at zero never fires and one at one fires on room
    /// tone, so neither end of the bar may reach them.
    func testTheDerivedSensitivityIsHeldInsideTenAndNinetyFivePercent() {
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0.95), 0.1, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0), 0.95, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: -3), 0.95, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 9), 0.1, accuracy: 0.0001)
    }

    /// The key is kept for compatibility with a build that still reads it, but a value
    /// stored in it can no longer contradict the marker.
    func testAStoredSensitivityIsIgnoredAndTheKeyIsStillWritten() throws {
        let defaults = try makeDefaults()
        defaults.set(0.02, forKey: "sensitivity")
        defaults.set(0.4, forKey: "partyGate")
        let settings = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.partyGate, 0.4, accuracy: 0.0001)
        XCTAssertEqual(settings.sensitivity, 0.6, accuracy: 0.0001,
                       "A stale stored sensitivity must not win over the marker.")

        SettingsStore(defaults: defaults).save(settings)
        XCTAssertEqual(defaults.double(forKey: "sensitivity"), 0.6, accuracy: 0.0001,
                       "The key is still written, for an older build installed over this one.")
    }

    func testSnapAndFadeDefaultRoundTripAndClamp() {
        let name = "GlowbeatSettingsTests.snapFade.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        // The defaults are stated as the feel they produce, not as two bare slider
        // numbers: out of the box the room runs Punchy, which is an instant rise and a
        // 0.3 s settle. The Effects package keeps its own `standard` timing for an
        // effect built without the engine, and the two are deliberately no longer equal.
        let shipped = EffectTiming.from(snap: GlowbeatSettings.defaults.partySnap,
                                        fade: GlowbeatSettings.defaults.partyFade)
        XCTAssertEqual(shipped.attack, PartyPreset.punchy.attack, accuracy: 0.0005)
        XCTAssertEqual(shipped.release, PartyPreset.punchy.release, accuracy: 0.005)
        XCTAssertEqual(shipped.release, 0.3, accuracy: 0.005)
        XCTAssertLessThan(shipped.attack, EffectTiming.standard.attack,
                          "Punchy rises faster than the Effects package's own default.")

        var settings = GlowbeatSettings.defaults
        settings.partySnap = 0.3
        settings.partyFade = 0.8
        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.partySnap, 0.3, accuracy: 0.0001)
        XCTAssertEqual(loaded.partyFade, 0.8, accuracy: 0.0001)

        defaults.set(7.0, forKey: "partySnap")
        defaults.set(-2.0, forKey: "partyFade")
        let clamped = store.load()
        XCTAssertEqual(clamped.partySnap, 1)
        XCTAssertEqual(clamped.partyFade, 0)
    }

    // MARK: Spread band assignment

    /// Nobody has chosen on a fresh install, so the map is empty and every bulb takes
    /// the round robin fallback.
    func testSpreadAssignmentsStartEmptyAndRoundTrip() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().spreadAssignments, [:])

        var settings = store.load()
        settings.spreadAssignments = ["AA:00": SpreadGroup.high.rawValue,
                                      "AA:01": SpreadGroup.bass.rawValue]
        store.save(settings)
        XCTAssertEqual(store.load().spreadAssignments,
                       ["AA:00": SpreadGroup.high.rawValue,
                        "AA:01": SpreadGroup.bass.rawValue])
    }

    /// A hand edited plist, or a group that stops existing in a later version, must not
    /// put a bulb on a band the effect has never heard of.
    func testSpreadAssignmentsDropAnythingThatIsNotAGroup() throws {
        let defaults = try makeDefaults()
        defaults.set(["good": SpreadGroup.mid.rawValue,
                      "outOfRange": 7,
                      "negative": -1,
                      "notANumber": "high"] as [String: Any],
                     forKey: "spreadAssignments")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().spreadAssignments,
                       ["good": SpreadGroup.mid.rawValue])
    }

    /// Anything but a dictionary in that key is ignored rather than crashing the launch.
    func testSpreadAssignmentsSurviveAWrongTypeInTheStore() throws {
        let defaults = try makeDefaults()
        defaults.set("not a dictionary", forKey: "spreadAssignments")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().spreadAssignments, [:])
    }

    /// Always react ships off: the marker is still the control until someone turns it
    /// off deliberately.
    func testAlwaysReactsDefaultsToOffAndRoundTrips() {
        let name = "GlowbeatSettingsTests.always.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(GlowbeatSettings.defaults.alwaysReacts)
        XCTAssertFalse(store.load().alwaysReacts, "An empty store must read as off.")

        var settings = GlowbeatSettings.defaults
        settings.alwaysReacts = true
        store.save(settings)
        XCTAssertTrue(store.load().alwaysReacts)
        XCTAssertTrue(defaults.bool(forKey: "alwaysReacts"))

        settings.alwaysReacts = false
        store.save(settings)
        XCTAssertFalse(store.load().alwaysReacts)
    }

    /// The detector is pinned to the middle of its range while the marker is grayed, so
    /// the number has to sit where the marker cannot reach it by accident.
    func testAlwaysReactPinsTheDetectorToTheMiddleOfItsRange() {
        XCTAssertEqual(GlowbeatSettings.alwaysReactsSensitivity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.derivedSensitivity(forGate: 0.5),
                       GlowbeatSettings.alwaysReactsSensitivity, accuracy: 0.0001,
                       "The pinned value is the middle of the same scale the marker uses.")
    }

    func testWaveTravelSpeedDefaultRoundTripsAndClamps() {
        let name = "GlowbeatSettingsTests.travel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        // Out of the box Wave travels exactly as it did before the slider existed: ten
        // bulbs a second, which is one hop per tick at the shipped update rate.
        XCTAssertEqual(GlowbeatSettings.defaults.waveTravelSpeed,
                       WaveEffect.defaultTravelSpeed, accuracy: 0.0001)
        XCTAssertEqual(store.load().waveTravelSpeed, 10, accuracy: 0.0001)

        var settings = GlowbeatSettings.defaults
        settings.waveTravelSpeed = 3
        store.save(settings)
        XCTAssertEqual(store.load().waveTravelSpeed, 3, accuracy: 0.0001)

        defaults.set(99.0, forKey: "waveTravelSpeed")
        XCTAssertEqual(store.load().waveTravelSpeed, 15, accuracy: 0.0001)
        defaults.set(0.0, forKey: "waveTravelSpeed")
        XCTAssertEqual(store.load().waveTravelSpeed, 1, accuracy: 0.0001)

        // A hand edited plist cannot get an out of range speed back out through a save
        // either.
        settings.waveTravelSpeed = 400
        store.save(settings)
        XCTAssertEqual(defaults.double(forKey: "waveTravelSpeed"), 15, accuracy: 0.0001)
    }

    /// Confetti ships off, is remembered, and is a plain bool in the plist.
    func testConfettiIsOffByDefaultAndRoundTrips() {
        let name = "GlowbeatSettingsTests.confetti.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(GlowbeatSettings.defaults.partyConfetti)
        XCTAssertFalse(store.load().partyConfetti)

        var settings = GlowbeatSettings.defaults
        settings.partyConfetti = true
        store.save(settings)
        XCTAssertTrue(store.load().partyConfetti)
        XCTAssertTrue(defaults.bool(forKey: "partyConfetti"))

        settings.partyConfetti = false
        store.save(settings)
        XCTAssertFalse(store.load().partyConfetti)
    }

    // MARK: The saved Advanced default

    /// The one setting that is deliberately absent until the user makes it. Nil means
    /// "Reset goes back to Punchy", so an empty store has to stay empty rather than
    /// quietly writing the shipped values into the slot.
    func testTheSavedAdvancedDefaultStartsEmptyRoundTripsAndClears() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.load().savedAdvancedDefault)
        XCTAssertEqual(store.load().effectiveAdvancedDefault,
                       AdvancedValues(preset: .punchy),
                       "With nothing saved, Reset goes back to Punchy.")

        var settings = store.load()
        let saved = AdvancedValues(floor: 0.22, ceiling: 0.66, snap: 0.4, fade: 0.8)
        settings.savedAdvancedDefault = saved
        store.save(settings)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.savedAdvancedDefault, saved)
        XCTAssertEqual(reloaded.effectiveAdvancedDefault, saved)
        XCTAssertEqual(reloaded, settings)

        settings.savedAdvancedDefault = nil
        store.save(settings)
        XCTAssertNil(store.load().savedAdvancedDefault,
                     "Clearing the default has to remove the key, not leave the old one.")
        XCTAssertEqual(store.load().effectiveAdvancedDefault, AdvancedValues(preset: .punchy))
    }

    /// Same rule as every other stored value: a hand edited plist cannot put the app
    /// somewhere the sliders cannot go, and anything that is not four numbers is not a
    /// default at all.
    func testAHandEditedSavedAdvancedDefaultIsClampedOrDropped() throws {
        let defaults = try makeDefaults()
        defaults.set(["floor": 0.9, "ceiling": 0.2, "snap": 7.0, "fade": -3.0],
                     forKey: "savedAdvancedDefault")
        let clamped = try XCTUnwrap(SettingsStore(defaults: defaults).load().savedAdvancedDefault)
        XCTAssertEqual(clamped.snap, 1)
        XCTAssertEqual(clamped.fade, 0)
        XCTAssertGreaterThanOrEqual(clamped.ceiling - clamped.floor,
                                    GlowbeatSettings.minimumBrightnessSpan,
                                    "An inverted range would save a room that cannot react.")

        defaults.set(["floor": 0.1, "ceiling": 0.9, "snap": 0.5], forKey: "savedAdvancedDefault")
        XCTAssertNil(SettingsStore(defaults: defaults).load().savedAdvancedDefault,
                     "Three quarters of a default is not a default.")

        defaults.set("punchy", forKey: "savedAdvancedDefault")
        XCTAssertNil(SettingsStore(defaults: defaults).load().savedAdvancedDefault)
    }

    /// The two buttons are dimmed when nothing would change, and "nothing would change"
    /// is this comparison. It runs on the same tolerance the Feel row recognizes a preset
    /// by, so a value that came back off disk still counts as the value that was saved.
    func testAdvancedValuesMatchOnTheSameToleranceTheFeelRowUses() {
        let base = AdvancedValues(floor: 0.2, ceiling: 0.7, snap: 0.5, fade: 0.5)
        XCTAssertTrue(base.matches(base))

        let inside = PartyPreset.tolerance / 2
        XCTAssertTrue(base.matches(AdvancedValues(floor: 0.2 + inside,
                                                  ceiling: 0.7 - inside,
                                                  snap: 0.5 + inside,
                                                  fade: 0.5 - inside)))

        let outside = PartyPreset.tolerance * 4
        let drags: [(String, AdvancedValues)] = [
            ("Darkest", AdvancedValues(floor: 0.2 + outside, ceiling: 0.7, snap: 0.5, fade: 0.5)),
            ("Brightest", AdvancedValues(floor: 0.2, ceiling: 0.7 - outside, snap: 0.5, fade: 0.5)),
            ("Snap", AdvancedValues(floor: 0.2, ceiling: 0.7, snap: 0.5 + outside, fade: 0.5)),
            ("Fade", AdvancedValues(floor: 0.2, ceiling: 0.7, snap: 0.5, fade: 0.5 - outside)),
        ]
        for (name, moved) in drags {
            XCTAssertFalse(base.matches(moved), "\(name) moved and the buttons stayed dimmed.")
        }
    }

    /// A feel is four values too, so the two have to agree about what they are.
    func testAdvancedValuesReadEveryFeel() {
        for preset in PartyPreset.allCases {
            var settings = GlowbeatSettings.defaults
            settings.partyFloor = preset.floor
            settings.partyCeiling = preset.ceiling
            settings.partySnap = preset.snap
            settings.partyFade = preset.fade
            XCTAssertEqual(settings.advancedValues, AdvancedValues(preset: preset),
                           preset.displayName)
        }
    }
}
