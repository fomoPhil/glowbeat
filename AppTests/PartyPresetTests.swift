import XCTest
import Effects
@testable import Glowbeat

/// The four feels, as the numbers they promise, as the words the readouts print, and as
/// the thing the picker has to recognize again when it sees them come back off disk.
///
/// On the main actor because the readout formatters live on the SwiftUI row that prints
/// them, and asking the row what it would print is the whole point of half of these.
@MainActor
final class PartyPresetTests: XCTestCase {

    /// The table from the brief. Every one of these numbers is what the Advanced sliders
    /// print once the feel is applied, so if a formatter or a curve moves, this fails
    /// rather than the picker quietly starting to lie.
    private struct Expectation {
        let preset: PartyPreset
        let displayName: String
        let summary: String
        let floor: Double
        let ceiling: Double
        let snapText: String
        let fadeText: String
    }

    private let expectations: [Expectation] = [
        Expectation(preset: .punchy,
                    displayName: "Punchy",
                    summary: "Fast and bright.",
                    floor: 0.10,
                    ceiling: 1.00,
                    snapText: "instant",
                    fadeText: "0.3 s"),
        Expectation(preset: .mellow,
                    displayName: "Mellow",
                    summary: "Low and slow.",
                    floor: 0.35,
                    ceiling: 0.80,
                    snapText: "0.06 s",
                    fadeText: "1.5 s"),
        Expectation(preset: .dreamy,
                    displayName: "Dreamy",
                    summary: "Soft hits, long settle.",
                    floor: 0.20,
                    ceiling: 0.70,
                    snapText: "0.25 s",
                    fadeText: "3.0 s"),
        Expectation(preset: .tight,
                    displayName: "Tight",
                    summary: "Sharp flicker, goes dark between hits.",
                    floor: 0.00,
                    ceiling: 1.00,
                    snapText: "instant",
                    // The Fade floor is 0.15 s and the readout prints one decimal, so
                    // the tightest setting has always printed "0.1 s".
                    fadeText: "0.1 s"),
    ]

    func testEveryFeelIsOnTheRowInTheOrderTheBriefSetsOut() {
        XCTAssertEqual(PartyPreset.allCases, [.punchy, .mellow, .dreamy, .tight])
        XCTAssertEqual(PartyPreset.allCases.map(\.displayName),
                       expectations.map(\.displayName))
    }

    /// The whole point of stating the presets as times: what the sliders print after a
    /// feel is tapped is what the feel is called on the tin.
    func testEveryFeelPrintsTheNumbersItPromises() {
        for expected in expectations {
            let preset = expected.preset
            XCTAssertEqual(preset.summary, expected.summary)
            XCTAssertEqual(LabeledValueSlider.percent(preset.floor),
                           "\(Int((expected.floor * 100).rounded()))%",
                           "\(preset.displayName) Darkest")
            XCTAssertEqual(LabeledValueSlider.percent(preset.ceiling),
                           "\(Int((expected.ceiling * 100).rounded()))%",
                           "\(preset.displayName) Brightest")
            XCTAssertEqual(LabeledValueSlider.snapSeconds(preset.snap),
                           expected.snapText,
                           "\(preset.displayName) Snap")
            XCTAssertEqual(LabeledValueSlider.fadeSeconds(preset.fade),
                           expected.fadeText,
                           "\(preset.displayName) Fade")
        }
    }

    /// The slider positions are derived from the times, so the round trip through
    /// `EffectTiming` has to land back on the time the preset asked for.
    func testEveryFeelRoundTripsThroughTheTimingCurves() {
        for expected in expectations {
            let timing = EffectTiming.from(snap: expected.preset.snap,
                                           fade: expected.preset.fade)
            XCTAssertEqual(timing.attack, expected.preset.attack, accuracy: 0.0005,
                           "\(expected.displayName) attack")
            XCTAssertEqual(timing.release, expected.preset.release, accuracy: 0.005,
                           "\(expected.displayName) release")
            XCTAssertTrue((0...1).contains(expected.preset.snap))
            XCTAssertTrue((0...1).contains(expected.preset.fade))
        }
    }

    /// No feel may ask for a range the sliders would have to correct, or tapping it
    /// would land somewhere other than where it says.
    func testNoFeelCollapsesTheBrightnessRange() {
        for preset in PartyPreset.allCases {
            let range = GlowbeatSettings.brightnessRange(settingFloor: preset.floor,
                                                         ceiling: preset.ceiling)
            XCTAssertEqual(range.floor, preset.floor, accuracy: 0.0001, preset.displayName)
            XCTAssertEqual(range.ceiling, preset.ceiling, accuracy: 0.0001, preset.displayName)
        }
    }

    func testMatchingPresetRecognizesEachFeelFromItsOwnValues() {
        for preset in PartyPreset.allCases {
            var settings = GlowbeatSettings.defaults
            settings.partyFloor = preset.floor
            settings.partyCeiling = preset.ceiling
            settings.partySnap = preset.snap
            settings.partyFade = preset.fade
            XCTAssertEqual(settings.matchingPreset, preset)
        }
    }

    /// Dragging any of the four sliders has to drop the picker to Custom. It falls out
    /// of the match rather than being a separate flag, so there is nothing to keep in
    /// step.
    func testMovingAnyOneSliderDropsTheFeelToCustom() {
        for preset in PartyPreset.allCases {
            var base = GlowbeatSettings.defaults
            base.partyFloor = preset.floor
            base.partyCeiling = preset.ceiling
            base.partySnap = preset.snap
            base.partyFade = preset.fade

            let nudge = PartyPreset.tolerance * 4
            let drags: [(String, (inout GlowbeatSettings) -> Void)] = [
                ("Darkest", { $0.partyFloor += nudge }),
                ("Brightest", { $0.partyCeiling -= nudge }),
                ("Snap", { $0.partySnap -= nudge }),
                ("Fade", { $0.partyFade += nudge }),
            ]
            for (name, change) in drags {
                var moved = base
                change(&moved)
                XCTAssertNil(moved.matchingPreset,
                             "\(name) moved off \(preset.displayName) and the row still says "
                             + "\(preset.displayName).")
            }
        }
    }

    /// A stored value comes back off disk as a `Double` written by this same code, so a
    /// feel has to survive the trip. The tolerance is what covers the last bit of it.
    func testAFeelSurvivesTheStore() throws {
        let name = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)

        for preset in PartyPreset.allCases {
            var settings = store.load()
            settings.partyFloor = preset.floor
            settings.partyCeiling = preset.ceiling
            settings.partySnap = preset.snap
            settings.partyFade = preset.fade
            store.save(settings)
            XCTAssertEqual(store.load().matchingPreset, preset)
        }
    }

    /// Glowbeat ships on Punchy. Phil's call on 2026-09-14: the shipped defaults are the
    /// Punchy numbers themselves, derived from the preset rather than retyped, so a fresh
    /// install shows Punchy on the Feel row rather than Custom.
    func testTheShippedDefaultsArePunchy() {
        XCTAssertEqual(GlowbeatSettings.defaults.matchingPreset, .punchy)
        XCTAssertEqual(GlowbeatSettings.defaults.partyFloor, PartyPreset.punchy.floor,
                       accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.defaults.partyCeiling, PartyPreset.punchy.ceiling,
                       accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.defaults.partySnap, PartyPreset.punchy.snap,
                       accuracy: 0.0001)
        XCTAssertEqual(GlowbeatSettings.defaults.partyFade, PartyPreset.punchy.fade,
                       accuracy: 0.0001)
    }

    /// The Effects package keeps its own defaults for an effect built without the engine,
    /// and they are not Punchy. Stated so the two cannot be quietly conflated again.
    func testTheEffectsPackageKeepsItsOwnDefaultTiming() {
        XCTAssertEqual(EffectTiming.standard.attack, 0.05, accuracy: 0.0001)
        XCTAssertEqual(EffectTiming.standard.release, 0.5, accuracy: 0.0001)
        XCTAssertNotEqual(GlowbeatSettings.defaults.partySnap, EffectTiming.standardSnap)
        XCTAssertNotEqual(GlowbeatSettings.defaults.partyFade, EffectTiming.standardFade)
    }
}
