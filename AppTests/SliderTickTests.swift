import XCTest
import AppKit
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// No slider in Glowbeat draws tick marks, and the two that count in whole units still
/// snap to them.
///
/// Phil, 2026-09-17: "there are little tick marks under some of the sliders. remove all
/// visual tick marks." On macOS the marks are not something the app asked for: AppKit
/// draws them for any `Slider(value:in:step:)`, so the rule is enforced against the
/// source rather than against a picture, where a row of hairlines is exactly the thing a
/// human eye slides over.
@MainActor
final class SliderTickTests: XCTestCase {

    private var socket: LANSocket!
    private var suiteName = ""
    private var fakeBulbs: [FakeBulb] = []

    private static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App", isDirectory: true)
    }

    private static var snapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }

    private func makeModel(bulbCount: Int) throws -> AppModel {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: "AA:0\($0)") }
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
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
                        loginItems: FakeLoginItemService())
    }

    override func tearDown() async throws {
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: The rule, enforced against the source

    /// Every `Slider(...)` written anywhere in the app, with no `step:` in any of them.
    ///
    /// A source scan rather than a pixel comparison: `step:` is the one and only thing
    /// that makes macOS draw the marks, it is a single token, and a test that reads the
    /// source catches a slider added to a pane this suite never renders.
    func testNoSliderInTheAppIsGivenAStep() throws {
        let calls = try Self.sliderCalls()
        XCTAssertGreaterThan(calls.count, 5,
                             "The scanner found \(calls.count) sliders, which is fewer "
                             + "than the app has, so it is not looking where it should.")
        for call in calls {
            XCTAssertFalse(call.text.contains("step:"),
                           "\(call.file) draws tick marks: \(call.text)")
        }
    }

    /// The stepping behavior is what `step:` was there for, so the replacement has to be
    /// somewhere. It is `LabeledValueSlider.snapsTo`.
    func testTheSlidersThatCountInWholeUnitsStillSnap() throws {
        let sources = try Self.appSources()
        let snapping = sources.filter { Self.code(in: $0.text).contains("snapsTo:") }
        XCTAssertFalse(snapping.isEmpty,
                       "Nothing snaps any more, so Travel and the ramps went continuous.")
    }

    // MARK: The snapping itself

    func testASnappingSliderRoundsToWholeUnits() {
        let range = WaveEffect.travelRange
        XCTAssertEqual(LabeledValueSlider.snapped(7.4, snapsTo: 1, in: range), 7)
        XCTAssertEqual(LabeledValueSlider.snapped(7.6, snapsTo: 1, in: range), 8)
        XCTAssertEqual(LabeledValueSlider.snapped(7.5, snapsTo: 1, in: range), 8)
    }

    func testASnappingSliderHonorsAStepThatIsNotOne() {
        XCTAssertEqual(LabeledValueSlider.snapped(37, snapsTo: 5, in: 0...100), 35)
        XCTAssertEqual(LabeledValueSlider.snapped(38, snapsTo: 5, in: 0...100), 40)
    }

    /// A range that does not start on a multiple of the step still snaps to the range's
    /// own marks, which is what the wake brightness slider (1 through 100) needs.
    func testSnappingIsMeasuredFromTheStartOfTheRange() {
        XCTAssertEqual(LabeledValueSlider.snapped(50.4, snapsTo: 1, in: 1...100), 50)
        XCTAssertEqual(LabeledValueSlider.snapped(1.4, snapsTo: 1, in: 1...100), 1)
    }

    func testSnappingClampsToTheRange() {
        let range = WaveEffect.travelRange
        XCTAssertEqual(LabeledValueSlider.snapped(-4, snapsTo: 1, in: range), 1)
        XCTAssertEqual(LabeledValueSlider.snapped(99, snapsTo: 1, in: range), 15)
        XCTAssertEqual(LabeledValueSlider.snapped(.nan, snapsTo: 1, in: range), 1)
    }

    /// Darkest, Brightest, Snap and Fade are measured rather than counted, so they stay
    /// exactly where the drag left them.
    func testAContinuousSliderIsLeftAlone() {
        XCTAssertEqual(LabeledValueSlider.snapped(0.3725, snapsTo: nil, in: 0...1),
                       0.3725,
                       accuracy: 0.000_001)
    }

    func testAContinuousSliderStillClamps() {
        XCTAssertEqual(LabeledValueSlider.snapped(4, snapsTo: nil, in: 0...1), 1)
        XCTAssertEqual(LabeledValueSlider.snapped(-4, snapsTo: nil, in: 0...1), 0)
    }

    /// A step of zero or less would divide by it. Treated as no step at all.
    func testAStepOfZeroIsIgnoredRatherThanDividedBy() {
        XCTAssertEqual(LabeledValueSlider.snapped(0.37, snapsTo: 0, in: 0...1),
                       0.37,
                       accuracy: 0.000_001)
    }

    // MARK: The state the marks used to be drawn in

    /// Wave is the effect with the Travel slider, and Travel is the slider Phil was
    /// looking at. Renders the pane in that state and leaves the image behind.
    func testTheWaveTravelStateRendersWithoutTicks() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setEffect(.wave)
        model.setWaveTravelSpeed(7)
        XCTAssertEqual(model.settings.waveTravelSpeed, 7)

        try write(pane(model: model, pane: .party, scheme: .dark), named: "ticks-party-travel")
    }

    func testTheScenesSpeedSliderRenders() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setScene(kind: .fixed)

        try write(pane(model: model, pane: .scenes, scheme: .dark), named: "ticks-scenes-speed")
    }

    /// The Schedule pane owns three of the five sliders that used to be stepped.
    func testTheScheduleRampSlidersRender() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setScheduleEnabled(true)
        model.setWakeRamp(minutes: 15)
        model.setSleepRamp(minutes: 20)
        model.setWakeBrightness(70)
        model.setLightMode(.auto)

        try write(pane(model: model, pane: .schedule, scheme: .dark), named: "ticks-schedule")
    }


    // MARK: The rule, enforced against what AppKit really builds

    /// Every slider the app actually puts on screen, with no tick marks on any of them.
    ///
    /// The definitive test, and the reason the source scan above is worded the way it is.
    /// `Slider(value:in:step:)` is drawn by an `NSSlider` with `numberOfTickMarks` set to
    /// one per step and `allowsTickMarkValuesOnly` on; a continuous slider leaves both
    /// alone. Measured on macOS 26 with a 1 through 15 range: stepped gives 15 marks,
    /// continuous gives 0. So rather than compare pictures, this walks the real AppKit
    /// view tree the app builds and reads the property the marks come from.
    ///
    /// `ImageRenderer` cannot help here at all: it paints a red "not supported" glyph
    /// over every slider, which is why the PNGs beside this file show yellow rectangles
    /// where the controls are.
    func testNoSliderTheAppDrawsHasTickMarks() async throws {
        let model = try makeModel(bulbCount: 6)
        defer { model.stopServices() }
        model.startServices()
        await waitForBulbs(model, count: 6)
        model.setEffect(.wave)
        model.setScheduleEnabled(true)
        model.setLightMode(.auto)

        var total = 0
        for pane in SidebarPane.allCases {
            model.setSelectedPane(pane)
            let sliders = Self.sliders(in: MainWindowView(model: model).snapshotLayout)
            for slider in sliders {
                XCTAssertEqual(slider.numberOfTickMarks, 0,
                               "The \(pane.title) pane draws a slider with "
                               + "\(slider.numberOfTickMarks) tick marks.")
            }
            total += sliders.count
        }

        for (name, sliders) in [("Settings", Self.sliders(in: SettingsView(model: model))),
                                ("the menu bar popover",
                                 Self.sliders(in: MenuBarContentView(model: model)))] {
            for slider in sliders {
                XCTAssertEqual(slider.numberOfTickMarks, 0,
                               "\(name) draws a slider with \(slider.numberOfTickMarks) "
                               + "tick marks.")
            }
            total += sliders.count
        }

        XCTAssertGreaterThan(total, 3,
                             "Only \(total) sliders were realized, so this found too "
                             + "little of the app to mean anything.")
    }

    /// Proves the property this suite reads is the one that changes, so a macOS release
    /// that stopped setting it would fail here rather than quietly making the rule above
    /// vacuous.
    func testASteppedSliderIsStillWhatSetsTickMarks() throws {
        let stepped = Self.sliders(in: Slider(value: .constant(5.0), in: 1...15, step: 1))
        let continuous = Self.sliders(in: Slider(value: .constant(5.0), in: 1...15))
        XCTAssertEqual(try XCTUnwrap(stepped.first).numberOfTickMarks, 15,
                       "A stepped slider no longer asks AppKit for tick marks, so the "
                       + "test above is measuring nothing.")
        XCTAssertEqual(try XCTUnwrap(continuous.first).numberOfTickMarks, 0)
    }

    // MARK: Helpers

    private func pane(model: AppModel, pane: SidebarPane, scheme: ColorScheme) -> some View {
        model.setSelectedPane(pane)
        return MainWindowView(model: model).snapshotLayout
            .frame(width: MainWindowMetrics.designWidth,
                   height: MainWindowMetrics.designHeight)
            .background(scheme == .dark
                        ? Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1E / 255)
                        : Color(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF5 / 255))
            .environment(\.colorScheme, scheme)
    }

    private func write(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) rendered nothing.")
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let directory = Self.snapshotDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        let representation = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]),
                                 "\(name) would not encode.")
        try data.write(to: url)
        print("[snapshot] \(url.path)")
    }

    private func waitForBulbs(_ model: AppModel, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.bulbs.count == count { return }
            model.rescan()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// Every `NSSlider` in the real AppKit tree a view builds.
    ///
    /// Hosted in a window and laid out, because an `NSHostingView` builds no platform
    /// subviews until it has both.
    private static func sliders(in view: some View) -> [NSSlider] {
        let host = NSHostingView(rootView: view.frame(width: MainWindowMetrics.designWidth,
                                                      height: MainWindowMetrics.designHeight))
        host.frame = NSRect(x: 0, y: 0,
                            width: MainWindowMetrics.designWidth,
                            height: MainWindowMetrics.designHeight)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        var found: [NSSlider] = []
        func walk(_ view: NSView) {
            if let slider = view as? NSSlider { found.append(slider) }
            for subview in view.subviews { walk(subview) }
        }
        walk(host)
        return found
    }

    // MARK: Reading the app's own source

    private struct Source {
        var file: String
        var text: String
    }

    private struct SliderCall {
        var file: String
        var text: String
    }

    private static func appSources() throws -> [Source] {
        let enumerator = FileManager.default.enumerator(at: appDirectory,
                                                        includingPropertiesForKeys: nil)
        var sources: [Source] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            sources.append(Source(file: url.lastPathComponent,
                                  text: try String(contentsOf: url, encoding: .utf8)))
        }
        if sources.isEmpty {
            throw XCTSkip("The app sources are not next to the tests in this run.")
        }
        return sources
    }

    /// The same file with its comments blanked out.
    ///
    /// A comment is allowed to name `Slider(value:in:step:)`, which is exactly what the
    /// code that stopped using it says about why. Only code is scanned, so the
    /// explanation cannot fail the rule it explains.
    private static func code(in source: String) -> String {
        var output = ""
        var characters = Array(source)[...]
        var inString = false
        var inLineComment = false
        var inBlockComment = 0
        while let character = characters.first {
            characters = characters.dropFirst()
            let next = characters.first
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                }
                continue
            }
            if inBlockComment > 0 {
                if character == "*", next == "/" {
                    inBlockComment -= 1
                    characters = characters.dropFirst()
                } else if character == "/", next == "*" {
                    inBlockComment += 1
                    characters = characters.dropFirst()
                } else if character == "\n" {
                    output.append(character)
                }
                continue
            }
            if inString {
                output.append(character)
                if character == "\\" {
                    if let next { output.append(next) }
                    characters = characters.dropFirst()
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "/", next == "/" {
                inLineComment = true
                characters = characters.dropFirst()
                continue
            }
            if character == "/", next == "*" {
                inBlockComment = 1
                characters = characters.dropFirst()
                continue
            }
            if character == "\"" { inString = true }
            output.append(character)
        }
        return output
    }

    /// Every `Slider(` in the app with its arguments, found by balancing parentheses
    /// rather than by a regular expression, because the calls run over several lines and
    /// carry nested calls of their own.
    private static func sliderCalls() throws -> [SliderCall] {
        var calls: [SliderCall] = []
        for source in try appSources() {
            let characters = Array(code(in: source.text))
            var index = 0
            let needle = Array("Slider(")
            while index + needle.count <= characters.count {
                guard Array(characters[index..<(index + needle.count)]) == needle else {
                    index += 1
                    continue
                }
                // "LabeledValueSlider(" and "SceneSpeedSlider(" end in the same seven
                // characters. Only a bare `Slider(` is the SwiftUI control.
                let previous = index > 0 ? characters[index - 1] : " "
                guard !previous.isLetter, !previous.isNumber, previous != "_" else {
                    index += needle.count
                    continue
                }
                var depth = 0
                var end = index + needle.count - 1
                while end < characters.count {
                    if characters[end] == "(" { depth += 1 }
                    if characters[end] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    end += 1
                }
                let upper = min(end + 1, characters.count)
                calls.append(SliderCall(file: source.file,
                                        text: String(characters[index..<upper])))
                index = upper
            }
        }
        return calls
    }
}
