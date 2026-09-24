import XCTest
import Effects
@testable import Glowbeat

/// The curated catalog of still colors, and the two settings that remember which one was
/// picked and how bright it was left.
///
/// The catalog is data, so what is worth testing about it is the invariants a swatch grid
/// and a bulb both depend on: no two ids alike, every white inside the H6004's range,
/// every channel a real channel, and no group left empty under its heading.
final class StillColorTests: XCTestCase {

    // MARK: The catalog

    func testTheCatalogIsAboutTwoDozenColors() {
        XCTAssertGreaterThanOrEqual(StillColor.all.count, 20)
        XCTAssertLessThanOrEqual(StillColor.all.count, 30,
                                 "A grid anyone can read at a glance is two dozen, not "
                                 + "a paint chart.")
    }

    func testEveryIDIsUnique() {
        let ids = StillColor.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "Two colors share an id, so the selection would ring both.")
    }

    func testEveryNameIsUnique() {
        let names = StillColor.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// Sentence case, the way every other label in the 05 look is written: "Golden hour",
    /// not "Golden Hour".
    func testEveryNameIsSentenceCase() {
        for color in StillColor.all {
            let words = color.name.split(separator: " ")
            XCTAssertFalse(words.isEmpty)
            for word in words.dropFirst() {
                XCTAssertFalse(word.first?.isUppercase ?? false,
                               "\(color.name) is title case.")
            }
            XCTAssertTrue(words[0].first?.isUppercase ?? false, "\(color.name)")
        }
    }

    func testEveryGroupHasColorsInIt() {
        for group in StillColorGroup.allCases {
            XCTAssertFalse(StillColor.colors(in: group).isEmpty,
                           "\(group.title) would draw a heading over nothing.")
        }
    }

    func testThereAreFourGroups() {
        XCTAssertEqual(StillColorGroup.allCases.count, 4)
        XCTAssertEqual(StillColorGroup.allCases.map(\.title),
                       ["Whites", "Sky", "Mood", "Playful"])
    }

    /// The catalog is listed in group order, so a view can walk it group by group and get
    /// the order it was written in rather than a sort.
    func testTheCatalogIsListedInGroupOrder() {
        let grouped = StillColorGroup.allCases.flatMap { StillColor.colors(in: $0) }
        XCTAssertEqual(grouped.map(\.id), StillColor.all.map(\.id))
    }

    /// The H6004's own white range. A Kelvin outside it is not a color the bulb has.
    func testEveryWhiteIsInsideTheBulbsRange() {
        for color in StillColor.all {
            guard case .white(let kelvin) = color.value else { continue }
            XCTAssertGreaterThanOrEqual(kelvin, ColorTemperatureRange.minimum, color.name)
            XCTAssertLessThanOrEqual(kelvin, ColorTemperatureRange.maximum, color.name)
        }
    }

    func testEveryWhiteIsInTheWhitesGroup() {
        for color in StillColor.all {
            if case .white = color.value {
                XCTAssertEqual(color.group, .whites, color.name)
            } else {
                XCTAssertNotEqual(color.group, .whites, color.name)
            }
        }
    }

    /// Not a tautology: `RGB` holds `UInt8`, so this says the colors were written as real
    /// channels rather than as a value that wrapped on the way in.
    func testEveryColorIsALitColor() {
        for color in StillColor.all {
            guard case .rgb(let rgb) = color.value else { continue }
            XCTAssertGreaterThan(Int(rgb.r) + Int(rgb.g) + Int(rgb.b), 0,
                                 "\(color.name) is black, which is a bulb that is off.")
        }
    }

    /// Whites are sent as Kelvin and everything else as RGB, which is the one thing the
    /// catalog's shape has to guarantee: the two go out as different commands.
    func testTheWhitesRunFromCandleToOvercast() {
        let kelvins = StillColor.colors(in: .whites).compactMap { color -> Int? in
            guard case .white(let kelvin) = color.value else { return nil }
            return kelvin
        }
        XCTAssertEqual(kelvins.count, StillColor.colors(in: .whites).count)
        XCTAssertEqual(kelvins.min(), 2700)
        XCTAssertEqual(kelvins.max(), 6500)
    }

    /// The one value Phil compares by eye: the Colors pane's Daylight and the Schedule
    /// pane's Daylight have to be the same white, or the checklist step reads as a bug.
    func testDaylightMatchesTheScheduleLightCard() throws {
        let daylight = try XCTUnwrap(StillColor.color(withID: "daylight"))
        XCTAssertEqual(daylight.value, .white(kelvin: WhiteTemperature.daylightKelvin))
    }

    func testLookingUpAColorByID() {
        XCTAssertEqual(StillColor.color(withID: "golden-hour")?.name, "Golden hour")
        XCTAssertNil(StillColor.color(withID: "ultraviolet-banana"))
    }

    // MARK: Brightness

    func testBrightnessIsHeldBetweenOnePercentAndFull() {
        XCTAssertEqual(StillColor.clampedBrightness(0.5), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(StillColor.clampedBrightness(4), 1)
        XCTAssertEqual(StillColor.clampedBrightness(0), StillColor.minimumBrightness)
        XCTAssertEqual(StillColor.clampedBrightness(-1), StillColor.minimumBrightness)
    }

    /// Zero is a bulb that is off, which is not a brightness anyone picked.
    func testTheFloorIsNotZero() {
        XCTAssertGreaterThan(StillColor.minimumBrightness, 0)
        XCTAssertEqual(StillColor.brightnessPercent(StillColor.minimumBrightness), 1)
    }

    func testANonFiniteBrightnessFallsBackToTheDefault() {
        XCTAssertEqual(StillColor.clampedBrightness(.nan), StillColor.defaultBrightness)
        XCTAssertEqual(StillColor.clampedBrightness(.infinity), 1)
    }

    func testBrightnessReadsAsWholePercent() {
        XCTAssertEqual(StillColor.brightnessPercent(0.7), 70)
        XCTAssertEqual(StillColor.brightnessPercent(0.705), 71)
        XCTAssertEqual(StillColor.brightnessPercent(1), 100)
    }

    // MARK: The settings

    func testAFreshInstallHasNoColorPickedAndSeventyPercent() {
        XCTAssertNil(GlowbeatSettings.defaults.stillColorID)
        XCTAssertEqual(GlowbeatSettings.defaults.stillBrightness, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(StillColor.defaultBrightness, 0.7, accuracy: 0.000_001)
    }

    func testTheSelectionAndTheBrightnessSurviveARelaunch() throws {
        let suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        var settings = GlowbeatSettings.defaults
        settings.stillColorID = "golden-hour"
        settings.stillBrightness = 0.42
        SettingsStore(defaults: defaults).save(settings)

        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.stillColorID, "golden-hour")
        XCTAssertEqual(reloaded.stillBrightness, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(reloaded.stillColor?.name, "Golden hour")
    }

    /// A color id from a hand edited plist, or from a build whose catalog had one this
    /// one does not, must not leave the pane ringing a swatch that is not there.
    func testAColorThisBuildDoesNotKnowIsDropped() throws {
        let suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        defaults.set("ultraviolet-banana", forKey: "stillColorID")
        let reloaded = SettingsStore(defaults: defaults).load()
        XCTAssertNil(reloaded.stillColorID)
        XCTAssertNil(reloaded.stillColor)
    }

    func testAHandEditedBrightnessIsClampedOnTheWayIn() throws {
        let suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        defaults.set(9.0, forKey: "stillBrightness")
        XCTAssertEqual(SettingsStore(defaults: defaults).load().stillBrightness, 1)
    }

    /// Clearing the selection has to survive a save, so "no color picked" is a real state
    /// and not only the state of an empty store.
    func testClearingTheSelectionSticks() throws {
        let suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        var settings = GlowbeatSettings.defaults
        settings.stillColorID = "lava"
        store.save(settings)
        XCTAssertEqual(store.load().stillColorID, "lava")

        settings.stillColorID = nil
        store.save(settings)
        XCTAssertNil(store.load().stillColorID)
    }
}
