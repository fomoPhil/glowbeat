import XCTest
import AppKit
import AudioTap
import Effects
import SwiftUI
import GoveeLAN
import GoveeLANTestSupport
@testable import Glowbeat

/// Smoothness investigation H1, 2026-09-23: does drawing the window delay Party Mode's
/// ticks?
///
/// Party Mode ticks on a dispatch timer on the main queue, and the window draws on the
/// same thread. This runs the real engine on the real timer, fed 50 frames a second, with
/// Phil's settings, and records when every tick actually fired, with no window and with
/// the real `MainWindowView` drawn in an `NSWindow` that is never put on screen.
///
/// A measurement, not a pass or fail check, so it is skipped unless asked for:
///
///     TEST_RUNNER_GLOWBEAT_MEASURE_TICKS=1 xcodebuild ... test \
///         -only-testing:GlowbeatTests/PartyTickJitterMeasurement
///
/// `GLOWBEAT_MEASURE_FRAMES` may name a frame cache written by the offline simulator, so
/// the level meter moves the way it does on real music; `GLOWBEAT_MEASURE_OUT` names a
/// folder for the results. Both pass through with the same `TEST_RUNNER_` prefix.
@MainActor
final class PartyTickJitterMeasurement: XCTestCase {

    private var socket: LANSocket?
    private var fakeBulbs: [FakeBulb] = []
    private var suiteName = ""
    private var windows: [NSWindow] = []

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        try XCTSkipUnless(Self.environment["GLOWBEAT_MEASURE_TICKS"] == "1",
                          "A measurement; set TEST_RUNNER_GLOWBEAT_MEASURE_TICKS=1 to run it.")
    }

    override func tearDown() async throws {
        for window in windows {
            window.contentView = nil
        }
        windows = []
        socket?.stop()
        socket = nil
        for bulb in fakeBulbs { bulb.stop() }
        fakeBulbs = []
        if !suiteName.isEmpty, let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            suiteName = ""
        }
    }

    // MARK: The variants

    func testTickTimingWithNoWindowSixBulbs() async throws {
        try await measure(label: "nowindow-6", bulbs: 6, draw: .none)
    }

    func testTickTimingWithNoWindowTenBulbs() async throws {
        try await measure(label: "nowindow-10", bulbs: 10, draw: .none)
    }

    func testTickTimingDrawingTheWindowEveryTickSixBulbs() async throws {
        try await measure(label: "display-6", bulbs: 6, draw: .everyTick)
    }

    func testTickTimingDrawingTheWindowEveryTickTenBulbs() async throws {
        try await measure(label: "display-10", bulbs: 10, draw: .everyTick)
    }

    func testTickTimingDrawingTheWindowSixtyTimesASecondTenBulbs() async throws {
        try await measure(label: "display60-10", bulbs: 10, draw: .sixtyHertz)
    }

    func testTickTimingRasterizingTheWindowEveryTickTenBulbs() async throws {
        try await measure(label: "bitmap-10", bulbs: 10, draw: .bitmapEveryTick)
    }

    // MARK: The harness

    private enum Draw {
        case none
        /// `display()` on the hosting view after every tick: layout and draw, the work a
        /// level change costs the main thread.
        case everyTick
        /// `display()` sixty times a second, as if an animation never stopped.
        case sixtyHertz
        /// A full rasterization of the window into a bitmap after every tick. Far more
        /// than the window server asks of the app; an upper bound.
        case bitmapEveryTick
    }

    private func measure(label: String, bulbs bulbCount: Int, draw: Draw) async throws {
        let seconds = Double(Self.environment["GLOWBEAT_MEASURE_SECONDS"] ?? "") ?? 20
        let recorder = TickRecorder()
        let model = try makeModel(bulbCount: bulbCount, tickSource: recorder)
        model.startServices()
        defer { model.stopServices() }
        let deadline = Date().addingTimeInterval(5)
        while model.bulbs.count < bulbCount, Date() < deadline {
            model.rescan()
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        XCTAssertEqual(model.bulbs.count, bulbCount)

        var hosting: NSHostingView<MainWindowView>?
        if draw != .none {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered,
                                  defer: false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: MainWindowView(model: model))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            windows.append(window)
            hosting = view
        }
        let drawTimes = DurationLog()
        switch draw {
        case .none, .sixtyHertz:
            break
        case .everyTick:
            recorder.afterTick = { [weak hosting] in
                guard let hosting else { return }
                let start = ProcessInfo.processInfo.systemUptime
                hosting.display()
                drawTimes.append(ProcessInfo.processInfo.systemUptime - start)
            }
        case .bitmapEveryTick:
            recorder.afterTick = { [weak hosting] in
                guard let hosting, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    return
                }
                let start = ProcessInfo.processInfo.systemUptime
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                drawTimes.append(ProcessInfo.processInfo.systemUptime - start)
            }
        }
        var sixty: DispatchSourceTimer?
        if draw == .sixtyHertz, let hosting {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
            timer.setEventHandler { [weak hosting] in
                MainActor.assumeIsolated {
                    guard let hosting else { return }
                    let start = ProcessInfo.processInfo.systemUptime
                    hosting.display()
                    drawTimes.append(ProcessInfo.processInfo.systemUptime - start)
                }
            }
            timer.resume()
            sixty = timer
        }
        defer { sixty?.cancel() }

        model.setPartyModeEnabled(true)
        let runningBy = Date().addingTimeInterval(5)
        while model.partyState != .running, Date() < runningBy {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.partyState, .running)

        let feeder = FrameFeeder(source: sourceForMeasurement, frames: Self.loadFrames())
        feeder.start()
        defer { feeder.stop() }
        // Let the gate, the auto gain and the detector warm up before counting.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        for bulb in fakeBulbs { bulb.clearRecordedCommands() }
        recorder.reset()
        drawTimes.reset()
        let monitor = MainThreadMonitor()
        monitor.start()
        let startedAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        monitor.stop()
        let ticks = recorder.snapshot()
        let colorSends = fakeBulbs.map { bulb in
            bulb.recordedCommands().filter { if case .color = $0 { return true }; return false }.count
        }
        let polls = fakeBulbs.map { bulb in bulb.recordedCommands().filter { $0 == .devStatus }.count }
        model.setPartyModeEnabled(false)

        let intervals = zip(ticks.starts.dropFirst(), ticks.starts).map { ($0 - $1) * 1000 }
        let results: [String: Any] = [
            "label": label,
            "bulbs": bulbCount,
            "seconds": elapsed,
            "ticks": ticks.starts.count,
            "intervalP50ms": Self.percentile(intervals, 50),
            "intervalP90ms": Self.percentile(intervals, 90),
            "intervalP99ms": Self.percentile(intervals, 99),
            "intervalMaxMs": intervals.max() ?? 0,
            "intervalMinMs": intervals.min() ?? 0,
            "ticksOver110ms": intervals.filter { $0 > 110 }.count,
            "ticksOver120ms": intervals.filter { $0 > 120 }.count,
            "ticksUnder80ms": intervals.filter { $0 < 80 }.count,
            "lateP50ms": Self.percentile(ticks.lateness.map { $0 * 1000 }, 50),
            "lateP99ms": Self.percentile(ticks.lateness.map { $0 * 1000 }, 99),
            "lateMaxMs": (ticks.lateness.max() ?? 0) * 1000,
            "tickWorkP50ms": Self.percentile(ticks.work.map { $0 * 1000 }, 50),
            "tickWorkP99ms": Self.percentile(ticks.work.map { $0 * 1000 }, 99),
            "tickWorkMaxMs": (ticks.work.max() ?? 0) * 1000,
            "drawCount": drawTimes.values.count,
            "drawP50ms": Self.percentile(drawTimes.values.map { $0 * 1000 }, 50),
            "drawP99ms": Self.percentile(drawTimes.values.map { $0 * 1000 }, 99),
            "drawMaxMs": (drawTimes.values.max() ?? 0) * 1000,
            "mainBusyPct": monitor.busyFraction(over: elapsed) * 100,
            "mainLongestBusyMs": monitor.longest * 1000,
            "mainBusyOver20ms": monitor.stretchesOver(0.020),
            "colorwcPerSecond": Double(colorSends.reduce(0, +)) / elapsed,
            "colorwcPerBulbPerSecondMin": Double(colorSends.min() ?? 0) / elapsed,
            "colorwcPerBulbPerSecondMax": Double(colorSends.max() ?? 0) / elapsed,
            "devStatusPerSecond": Double(polls.reduce(0, +)) / elapsed,
        ]
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
        let text = String(decoding: data, as: UTF8.self)
        print("H1 MEASUREMENT \(text)")
        let folder = URL(fileURLWithPath: Self.environment["GLOWBEAT_MEASURE_OUT"]
                         ?? FileManager.default.temporaryDirectory.path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("h1-\(label).json"))
        // Offsets from the first tick, one per line, for the offline simulator's --jitter.
        let offsets = ticks.starts.map { String(format: "%.6f", $0 - (ticks.starts.first ?? 0)) }
        try offsets.joined(separator: "\n").write(to: folder.appendingPathComponent("h1-\(label)-ticks.txt"),
                                                  atomically: true, encoding: .utf8)
    }

    private var sourceForMeasurement: ScriptedFrameSource!

    private func makeModel(bulbCount: Int, tickSource: any TickSource) throws -> AppModel {
        fakeBulbs = try (0..<bulbCount).map { try FakeBulb(deviceID: String(format: "AA:%02d", $0)) }
        suiteName = "glowbeat.tests.\(UUID().uuidString)"
        let configuration = LANConfiguration(replyPort: 0,
                                             commandPort: .matchingReplySource,
                                             joinsMulticast: false,
                                             extraScanTargets: fakeBulbs.map { $0.endpoint() })
        let socket = LANSocket(configuration: configuration)
        self.socket = socket
        try socket.start()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let source = ScriptedFrameSource()
        sourceForMeasurement = source
        let model = AppModel(socket: socket,
                             discovery: BulbDiscovery(socket: socket,
                                                      configuration: configuration,
                                                      rescanInterval: 60,
                                                      missesBeforeUnreachable: 3),
                             controller: BulbController(socket: socket),
                             poller: StatusPoller(socket: socket, configuration: configuration, interval: 10),
                             frameSource: source,
                             tickSource: tickSource,
                             sceneTickSource: ManualTickSource(),
                             scheduleTickSource: ManualIntervalTicker(),
                             nightShift: FakeNightShift(),
                             settingsStore: SettingsStore(defaults: defaults),
                             nameStore: BulbNameStore(defaults: defaults),
                             loginItems: FakeLoginItemService())
        model.completeFirstRun()
        // Phil's live settings, 2026-09-23.
        model.setEffect(.pulse)
        model.setPalette(id: Palette.blacklight.id)
        model.setPartyGate(0.6153562595129376)
        model.setPartyCeiling(1)
        model.setPartyFloor(0.5164999430931321)
        model.setPartySnap(1)
        model.setPartyFade(0.47216796875)
        model.setMaxUpdatesPerSecond(Int(Self.environment["GLOWBEAT_MEASURE_UPS"] ?? "") ?? 10)
        model.setSelectedPane(.party)
        return model
    }

    /// Frames from a cache the offline simulator wrote, or a synthetic 120 BPM kick.
    private static func loadFrames() -> [(rms: Float, bands: [Float])] {
        if let path = environment["GLOWBEAT_MEASURE_FRAMES"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 8 {
            return data.withUnsafeBytes { raw in
                let count = min(Int(raw.loadUnaligned(fromByteOffset: 0, as: Int64.self)), 50 * 120)
                var frames: [(rms: Float, bands: [Float])] = []
                var offset = 8
                for _ in 0..<count {
                    let rms = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                    let bands = (0..<5).map { raw.loadUnaligned(fromByteOffset: offset + 12 + $0 * 4, as: Float.self) }
                    frames.append((rms, bands))
                    offset += 32
                }
                return frames
            }
        }
        return (0..<(50 * 8)).map { index in
            let beat = index % 25 < 3
            let level: Float = beat ? 0.3 : 0.05 + 0.02 * Float(index % 7)
            return (level, [beat ? 0.4 : 0.05, beat ? 0.35 : 0.06, 0.05, 0.04, 0.03])
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }
}

/// The production timer, with every firing recorded: when it began, how late it was
/// against the schedule, and how long the engine's tick took.
@MainActor
private final class TickRecorder: TickSource {

    struct Snapshot {
        var starts: [TimeInterval]
        var lateness: [TimeInterval]
        var work: [TimeInterval]
    }

    private let inner = TimerTickSource()
    private var starts: [TimeInterval] = []
    private var lateness: [TimeInterval] = []
    private var work: [TimeInterval] = []
    private var firstStart: TimeInterval?
    private var interval: TimeInterval = 0.1
    var afterTick: (@MainActor () -> Void)?

    func start(ticksPerSecond: Int, handler: @escaping @MainActor () -> Void) {
        interval = 1.0 / Double(max(1, ticksPerSecond))
        inner.start(ticksPerSecond: ticksPerSecond) { [weak self] in
            let begin = ProcessInfo.processInfo.systemUptime
            handler()
            let end = ProcessInfo.processInfo.systemUptime
            guard let self else { return }
            if let firstStart {
                let scheduled = firstStart + (begin - firstStart).rounded(toMultipleOf: interval)
                lateness.append(max(0, begin - scheduled))
            } else {
                firstStart = begin
            }
            starts.append(begin)
            work.append(end - begin)
            afterTick?()
        }
    }

    func stop() {
        inner.stop()
    }

    func reset() {
        starts.removeAll()
        lateness.removeAll()
        work.removeAll()
        firstStart = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(starts: starts, lateness: lateness, work: work)
    }
}

private extension Double {
    func rounded(toMultipleOf step: Double) -> Double {
        (self / step).rounded(.down) * step
    }
}

/// Durations recorded on the main thread.
@MainActor
private final class DurationLog {
    private(set) var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
    func reset() { values.removeAll() }
}

/// How much of the time the main run loop spends awake, and its longest stretches.
@MainActor
private final class MainThreadMonitor {

    private var observer: CFRunLoopObserver?
    private var wokeAt: TimeInterval?
    private var busy: TimeInterval = 0
    private var stretches: [TimeInterval] = []

    var longest: TimeInterval { stretches.max() ?? 0 }

    func stretchesOver(_ threshold: TimeInterval) -> Int {
        stretches.filter { $0 > threshold }.count
    }

    func busyFraction(over elapsed: TimeInterval) -> Double {
        elapsed > 0 ? busy / elapsed : 0
    }

    func start() {
        wokeAt = ProcessInfo.processInfo.systemUptime
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                self?.note(activity)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
        note(.beforeWaiting)
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        if activity == .afterWaiting {
            wokeAt = now
        } else if activity == .beforeWaiting, let woke = wokeAt {
            let stretch = now - woke
            busy += stretch
            stretches.append(stretch)
            wokeAt = nil
        }
    }
}

/// Emits frames at 50 a second from a background queue, the way the tap does.
private final class FrameFeeder: @unchecked Sendable {

    private let source: ScriptedFrameSource
    private let frames: [(rms: Float, bands: [Float])]
    private let queue = DispatchQueue(label: "com.philwoolley.glowbeat.measure.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var index = 0

    init(source: ScriptedFrameSource, frames: [(rms: Float, bands: [Float])]) {
        self.source = source
        self.frames = frames
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.02, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !frames.isEmpty else { return }
            let frame = frames[index % frames.count]
            index += 1
            source.emit(AudioTap.AudioFrame(time: ProcessInfo.processInfo.systemUptime,
                                            rms: frame.rms,
                                            bands: frame.bands))
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
