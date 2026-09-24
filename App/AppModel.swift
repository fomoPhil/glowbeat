import AppKit
import AudioTap
import Effects
import Foundation
import GoveeLAN
import Network
import Observation
import OSLog

/// The one observable object the whole app reads from.
///
/// It owns the object graph (socket, discovery, controller, poller, Party Mode engine)
/// and is the only place where the packages are wired together. Every call it makes into
/// an actor or into the engine's asynchronous lifecycle is wrapped in a `Task` so the
/// main thread is never blocked. `PartyEngine.start` is the longest of them: it drains
/// the previous session's commands and then opens the audio tap, and the tap itself is
/// opened on a background executor, because building it takes tens of milliseconds and
/// `AudioDeviceStart` can sit behind the macOS permission prompt for as long as the user
/// takes to answer.
@MainActor
@Observable
final class AppModel {

    enum Banner: Equatable {
        case noBulbs
        case networkUnavailable
        case audioDenied
        case partyPaused(String)
    }

    // MARK: Published state

    private(set) var bulbs: [Bulb] = []
    private(set) var partyState: PartyEngine.State = .off
    private(set) var level: Float = 0
    private(set) var audioPermission: AudioTapPermission = .unknown
    private(set) var settings: GlowbeatSettings
    /// Whether the status item is on the menu bar right now, which is not the same thing
    /// as `settings.showsMenuBarExtra`. The setting is what the user asked for and only
    /// Settings may change it. This is what macOS actually did with that request, and it
    /// is what `MenuBarExtra(isInserted:)` reads, so an eviction from a full menu bar
    /// settles here in one write instead of being argued with on every update pass.
    private(set) var isMenuBarExtraInserted: Bool
    /// Set when `PartyEngine.start` threw, which in practice means the audio tap refused
    /// to open. The engine stays off in that case, so the banner needs its own reason to
    /// speak up rather than reading it off `partyState`.
    private(set) var audioStartFailed = false
    /// Whether the tap has heard any audio at all since Party Mode was switched on.
    ///
    /// The tap cannot tell a denied permission from a quiet Mac: both are three seconds
    /// of nothing, reported as `.deniedOrSilent`. Phil, 2026-09-22, ruled on the
    /// difference that is visible here. A session that has never heard anything gets the
    /// red "not hearing any audio" banner, because that is what a missing permission
    /// looks like. A session that has heard music and then goes quiet is a song ending,
    /// and only says "Waiting for music." in the status line.
    ///
    /// False when a session starts, true from the first `.granted` while one is running
    /// or still switching on, kept through a pause and a Resume, false again when Party
    /// Mode is switched off. The engine and the tap never see it: it is only how the UI
    /// reads the signal they already send.
    private(set) var hasHeardAudioThisSession = false
    /// True while a Party Mode start or resume is still in flight. The engine drops a
    /// second transition asked for during the first one, so the UI disables the toggle
    /// on this rather than the model quietly queueing taps the user cannot see.
    private(set) var isPartyTransitioning = false
    /// True when the LAN socket refused to open. Nothing can reach a bulb in that state,
    /// so the UI says so instead of blaming LAN Control in Govee Home.
    private(set) var networkUnavailable = false
    /// What the light mode is doing: which mode, what it is following, the temperature it
    /// is holding and when that turns over. The Schedule section's caption reads this.
    private(set) var lightModeStatus: LightModeEngine.Status
    /// Whether a wake or sleep ramp is part way through.
    private(set) var scheduleState: ScheduleEngine.State = .idle
    /// The still color the room is wearing right now, or nil when nothing put one there.
    ///
    /// Deliberately not the same thing as `settings.stillColor`, which is the swatch the
    /// Colors pane rings. A still color is one shot: it lands and then nothing repeats
    /// it, so the app cannot know the bulbs are still on it after a relaunch, and it
    /// stops being true the moment Party Mode, a scene or a Light transition repaints the
    /// room. This is the half that only claims what Glowbeat can still stand behind.
    private(set) var appliedStillColor: StillColor?

    // MARK: Dependencies

    private let socket: LANSocket
    private let discovery: BulbDiscovery
    private let controller: BulbController
    private let poller: StatusPoller
    private let settingsStore: SettingsStore
    private let nameStore: BulbNameStore
    private let ordering: BulbOrdering
    private let identifier: BulbIdentifier
    private let engine: PartyEngine
    /// Scenes: the non-music modes. Owns its own engine and its own tick source, so a
    /// scene and Party Mode never share a clock.
    private let scenes: SceneCoordinator
    /// Daylight, Night and Auto: what white the room sits at when nothing else drives it.
    private let lightModeEngine: LightModeEngine
    /// The wake and sleep timers. Owns the thirty second poll that also drives the light
    /// mode, so the two never disagree about what time it is.
    private let scheduleEngine: ScheduleEngine
    /// The login item, behind a protocol so the suite can never register a real one.
    private let loginItems: any LoginItemService
    /// Held for the model's lifetime alongside the engine. Their lifetimes are coupled:
    /// the engine's `deinit` ends the reader of this source's streams, so a source that
    /// outlived its engine would never be read again.
    private let frameSource: any AudioFrameSource
    private let changeDetector = ExternalChangeDetector()
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "AppModel")

    /// Status polling cadence while Party Mode runs, for a room of `bulbCount` bulbs.
    ///
    /// One second up to six bulbs, as spec section 4.4 has always had it. Past six the
    /// interval stretches so the whole room is asked `partyPollsPerSecond` times a second,
    /// the way the colors keep to `StreamRateLimiter.roomBudgetPerSecond`: a room of six
    /// at one poll a second each was the room that felt smooth, and every poll is a
    /// request and a reply on the same Wi-Fi as the colors.
    ///
    /// The cost is how fast a phone is caught. Power and brightness pause on the first
    /// poll that shows them, a color on the third that agrees (`ExternalChangeDetector`),
    /// so a phone is caught within one interval and within two to three intervals:
    /// 1 s and 2 to 3 s up to six bulbs, 1.7 s and 3.3 to 5 s at ten, 2.5 s and 5 to 7.5 s
    /// at fifteen, plus a reply's trip back.
    static func partyPollInterval(forBulbCount bulbCount: Int) -> TimeInterval {
        max(minimumPartyPollInterval, Double(bulbCount) / Double(partyPollsPerSecond))
    }

    private static let minimumPartyPollInterval: TimeInterval = 1
    /// Status requests a second for the whole room while Party Mode runs.
    static let partyPollsPerSecond = 6
    private static let idlePollInterval: TimeInterval = 10
    /// The most often a still color's brightness reaches the bulbs while its slider is
    /// being dragged.
    ///
    /// A drag produces a value on every frame and these are Wi-Fi bulbs with no retries
    /// and a rate limiter of their own. About six sends a second follows a finger closely
    /// enough to feel live and leaves the bulbs room to keep up. The release always sends,
    /// whether or not it falls inside a window the drag has already spent.
    static let stillBrightnessSendInterval: TimeInterval = 0.150

    /// How long to wait after a wake or a network path change before rebuilding the
    /// socket. macOS reports a burst of path changes while an interface settles, and
    /// rebuilding on the first one would just do it again a moment later.
    private static let networkRestartDebounce: TimeInterval = 2

    /// What Glowbeat believes a bulb should look like during a Party Mode session.
    ///
    /// Lazy on purpose. A session does not guess a baseline from anything it knew before
    /// it began: it takes the first status report that arrives after it starts, whatever
    /// that report says, and judges every later report against that. Anything the app
    /// sent before the session, and anything a phone did before the session, is equally
    /// history by then, and preferring the app's own last command over a fresh report
    /// used to pause a session for a change the user had made minutes earlier with Party
    /// Mode switched off. Commands the app sends during the session still win, because
    /// the controller's send history is checked first and is cleared on every start.
    private struct PartyBaseline {
        var power: Bool?
        var brightness: Int?
    }

    /// Created on the first `startServices` and then kept for the life of the model.
    /// Cancelling a task parked in `AsyncStream.next()` finishes that stream for good,
    /// and both of these streams are handed out once per object, so `stopServices` stops
    /// them with `isServicesRunning` instead. Only `deinit` cancels.
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var partyTask: Task<Void, Never>?
    /// Serializes everything that has to reach the discovery and poller actors in order,
    /// so a restart cannot overtake the stop it follows.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    /// Filled by the first status report each bulb sends after a session starts, and
    /// cleared on every start, resume and stop.
    @ObservationIgnored private var baselines: [String: PartyBaseline] = [:]
    /// Per bulb, the consecutive polls reporting a color the app cannot account for. Three
    /// in a row that agree with each other are a phone (`ExternalChangeDetector`).
    @ObservationIgnored private var colorMismatches: [String: ExternalChangeDetector.ColorMismatchRun] = [:]
    /// Which bulbs have shown the full brightness Party Mode sets as it starts. Until one
    /// has, its brightness is not judged: the command may simply not have landed yet.
    @ObservationIgnored private var brightnessCheck = ExternalChangeDetector.BrightnessCheck()
    /// Bumped on every start and resume. A takeover check that was already in flight
    /// across one of those transitions is measuring a baseline that no longer applies,
    /// so it drops its finding instead of pausing a freshly resumed session.
    @ObservationIgnored private var partySession = 0
    @ObservationIgnored private var isServicesRunning = false
    /// Set up by `startServices` and torn down by `stopServices`. Both outlive a socket
    /// restart, because a restart is the thing they ask for.
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathFingerprint: String?
    @ObservationIgnored private var networkRestartTask: Task<Void, Never>?
    /// The app's one wall clock seam, taken from the same parameter the schedule reads
    /// so a test that winds time winds it for everything at once. Only the still color's
    /// rate limiter uses it outside the schedule.
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// When the still brightness last reached a bulb, for the rate limiter above. Distant
    /// past rather than nil, so the first frame of the first drag always sends.
    @ObservationIgnored private var lastStillBrightnessSend = Date.distantPast

    init(socket: LANSocket,
         discovery: BulbDiscovery,
         controller: BulbController,
         poller: StatusPoller,
         frameSource: any AudioFrameSource,
         tickSource: any TickSource,
         sceneTickSource: any TickSource = TimerTickSource(),
         sceneClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTickSource: any IntervalTickSource = TimerIntervalTickSource(),
         scheduleClock: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current,
         nightShift: (any NightShiftSource)? = nil,
         settingsStore: SettingsStore,
         nameStore: BulbNameStore,
         loginItems: any LoginItemService,
         partyTrace: PartyTraceFactory? = nil) {
        self.socket = socket
        self.discovery = discovery
        self.controller = controller
        self.poller = poller
        self.settingsStore = settingsStore
        self.nameStore = nameStore
        self.loginItems = loginItems
        self.ordering = BulbOrdering(store: nameStore)
        self.identifier = BulbIdentifier(controller: controller)
        self.frameSource = frameSource
        self.clock = scheduleClock
        let loaded = settingsStore.load()
        self.settings = loaded
        self.isMenuBarExtraInserted = loaded.showsMenuBarExtra
        self.engine = PartyEngine(controller: controller,
                                  frameSource: frameSource,
                                  tickSource: tickSource,
                                  traceFactory: partyTrace)
        self.scenes = SceneCoordinator(controller: controller,
                                       tickSource: sceneTickSource,
                                       clock: sceneClock)
        self.lightModeEngine = LightModeEngine(controller: controller,
                                               source: nightShift,
                                               mode: loaded.lightMode,
                                               shiftLengthMinutes: loaded.shiftLengthMinutes,
                                               calendar: calendar)
        self.scheduleEngine = ScheduleEngine(controller: controller,
                                             ticker: scheduleTickSource,
                                             store: settingsStore,
                                             settings: loaded.schedule,
                                             clock: scheduleClock,
                                             calendar: calendar)
        self.lightModeStatus = self.lightModeEngine.status

        engine.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.partyState = newState
            self.updateLightModeSuspension()
        }
        engine.onLevelChange = { [weak self] newLevel in
            self?.level = newLevel
        }
        // The engine is the single reader of the source's permission stream. An
        // `AsyncStream` has one consumer, so the model takes its copy from here rather
        // than iterating the source itself and racing the engine for each value.
        engine.onPermissionChange = { [weak self] permission in
            guard let self else { return }
            self.audioPermission = permission
            // The start counts: the tap can hear its first frame before the engine is
            // back to call itself running, and it only reports again on a change.
            if permission == .granted, self.partyState != .off || self.isPartyTransitioning {
                self.hasHeardAudioThisSession = true
            }
        }
        self.audioPermission = engine.permission

        wireSchedule(clock: scheduleClock)
    }

    /// The Schedule half of the object graph. Three rules live here rather than in either
    /// engine, because each of them needs the rest of the app: a wake never interrupts
    /// music, a sleep stops it first, and the light mode holds off while anything else is
    /// driving the bulbs.
    private func wireSchedule(clock: @escaping @Sendable () -> Date) {
        lightModeEngine.onStatusChange = { [weak self] status in
            self?.lightModeStatus = status
        }
        scheduleEngine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.scheduleState = state
            self.updateLightModeSuspension()
        }
        scheduleEngine.onTick = { [weak self] now in
            self?.lightModeEngine.reconcile(at: now)
        }
        scheduleEngine.isBusy = { [weak self] in
            self?.isDrivingBulbs ?? false
        }
        scheduleEngine.currentKelvin = { [weak self] in
            self?.lightModeEngine.kelvin ?? WhiteTemperature.daylightKelvin
        }
        scheduleEngine.willRunSleep = { [weak self] in
            guard let self else { return }
            self.setPartyModeEnabled(false)
            self.scenes.stop()
            self.dropAppliedStillColor()
            self.identifier.cancelAll()
            self.updateLightModeSuspension()
        }
        // One silent look at the clock, so the light mode knows what it is following
        // before anything asks it. It adopts rather than paints: launching Glowbeat is
        // not a request to change the room.
        lightModeEngine.reconcile(at: clock())
        lightModeStatus = lightModeEngine.status
    }

    deinit {
        discoveryTask?.cancel()
        statusTask?.cancel()
        partyTask?.cancel()
        lifecycleTask?.cancel()
        networkRestartTask?.cancel()
    }

    /// Builds the production object graph.
    static func live() -> AppModel {
        let configuration = LANConfiguration.production
        let socket = LANSocket(configuration: configuration)
        let settingsStore = SettingsStore()
        let settings = settingsStore.load()
        let discovery = BulbDiscovery(socket: socket,
                                      configuration: configuration,
                                      rescanInterval: settings.rescanInterval,
                                      missesBeforeUnreachable: 3)
        let controller = BulbController(
            socket: socket,
            configuration: .init(repeatCount: 3,
                                 repeatInterval: 1.0,
                                 maxStreamedSendsPerSecond: settings.maxUpdatesPerSecond,
                                 recentColorHistoryCount: 5))
        let poller = StatusPoller(socket: socket,
                                  configuration: configuration,
                                  interval: idlePollInterval)
        return AppModel(socket: socket,
                        discovery: discovery,
                        controller: controller,
                        poller: poller,
                        frameSource: SystemAudioTap(),
                        tickSource: TimerTickSource(),
                        sceneTickSource: TimerTickSource(),
                        nightShift: NightShiftClient(),
                        settingsStore: settingsStore,
                        nameStore: BulbNameStore(),
                        loginItems: SMAppLoginItemService(),
                        partyTrace: .live(socket: socket))
    }

    // MARK: Services

    func startServices() {
        guard !isServicesRunning else { return }
        isServicesRunning = true
        openSocket()
        startReadersIfNeeded()
        startNetworkWatchers()
        lightModeEngine.startObserving()
        scheduleEngine.start()
        enqueueLifecycle { [discovery] in
            await discovery.start()
        }
    }

    /// Opens the socket and records whether it worked. A socket that will not open is
    /// the whole app: discovery, commands and polling all go through it, so the failure
    /// is surfaced rather than logged and forgotten.
    private func openSocket() {
        do {
            try socket.start()
            networkUnavailable = false
        } catch {
            logger.error("Unable to open the LAN socket: \(String(describing: error), privacy: .public)")
            networkUnavailable = true
        }
    }

    /// Not wired to app termination on purpose. Spec section 4.4 step 4: quitting never
    /// turns bulbs off and never restores anything, so the bulbs keep their last color.
    /// This exists for tests and for a future "disconnect" control.
    func stopServices() {
        guard isServicesRunning else { return }
        isServicesRunning = false
        // The socket is about to close, so a flash still running would spend its restore
        // on commands that reach nothing.
        identifier.cancelAll()
        engine.stop()
        scenes.stop()
        scheduleEngine.stop()
        lightModeEngine.stopObserving()
        partyTask?.cancel()
        partyTask = nil
        isPartyTransitioning = false
        baselines.removeAll()
        colorMismatches.removeAll()
        brightnessCheck.reset()
        // The reader tasks are deliberately left running: see the note on their
        // declarations. `isServicesRunning` makes them drop whatever still arrives.
        networkRestartTask?.cancel()
        networkRestartTask = nil
        stopNetworkWatchers()
        enqueueLifecycle { [discovery, poller] in
            await discovery.stop()
            await poller.stop()
        }
        socket.stop()
    }

    func rescan() {
        enqueueLifecycle { [discovery] in
            await discovery.scanNow()
        }
    }

    // MARK: Network recovery

    /// Rebuilds the socket and re-arms discovery and polling behind it.
    ///
    /// A socket that was bound before the Mac slept, or before Wi-Fi changed, is bound to
    /// an interface that may not exist any more: it keeps reporting success and nothing
    /// ever arrives. Closing it ends every datagram stream, which is what ends the
    /// generation tagged receive loops in discovery and the poller, so the `start` at the
    /// end of this chain arms fresh ones on the new socket.
    func restartNetwork() {
        guard isServicesRunning else { return }
        logger.log("Rebuilding the LAN socket after a wake or a network change.")
        enqueueLifecycle { [weak self, discovery, poller] in
            await discovery.stop()
            await poller.stop()
            await self?.reopenSocket()
            await discovery.start()
        }
    }

    private func reopenSocket() {
        socket.stop()
        openSocket()
    }

    /// Watches the two things that invalidate a live socket: waking from sleep, and the
    /// network path changing underneath it.
    private func startNetworkWatchers() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil) { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleNetworkRestart()
                        // Whatever came due behind a closed lid is caught here, against
                        // the wall clock, not replayed.
                        self?.scheduleEngine.reconcileNow()
                    }
                }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                // Only the shape of the path crosses back to the main actor, never the
                // path itself, and it is all the debounce needs to tell a real change
                // from a repeat of the state it already has.
                let fingerprint = "\(path.status) \(path.availableInterfaces.map(\.name).sorted())"
                Task { @MainActor in self?.applyNetworkPath(fingerprint) }
            }
            monitor.start(queue: DispatchQueue(label: "com.philwoolley.glowbeat.path"))
            pathMonitor = monitor
        }
    }

    private func stopNetworkWatchers() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathFingerprint = nil
    }

    /// The monitor reports the current path as soon as it starts, which is not a change.
    private func applyNetworkPath(_ fingerprint: String) {
        guard let previous = lastPathFingerprint else {
            lastPathFingerprint = fingerprint
            return
        }
        guard previous != fingerprint else { return }
        lastPathFingerprint = fingerprint
        scheduleNetworkRestart()
    }

    private func scheduleNetworkRestart() {
        guard isServicesRunning else { return }
        networkRestartTask?.cancel()
        let delay = Self.networkRestartDebounce
        networkRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.restartNetwork()
        }
    }

    /// Both readers are created from a MainActor method, so they inherit MainActor
    /// isolation and can touch `self` directly. The poller is armed by `applyDiscovered`
    /// once there is something to poll; `statuses` is created with the poller and
    /// buffers, so reading it from here cannot miss an update.
    private func startReadersIfNeeded() {
        if discoveryTask == nil {
            discoveryTask = Task { [weak self, updates = discovery.updates] in
                for await snapshot in updates {
                    guard let self else { return }
                    guard self.isServicesRunning else { continue }
                    self.applyDiscovered(self.ordering.sorted(snapshot))
                }
            }
        }
        if statusTask == nil {
            statusTask = Task { [weak self, statuses = poller.statuses] in
                for await update in statuses {
                    guard let self else { return }
                    guard self.isServicesRunning else { continue }
                    self.applyStatus(update)
                }
            }
        }
    }

    /// Runs `work` after everything already queued, so a start can never overtake the
    /// stop in front of it.
    private func enqueueLifecycle(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            await work()
        }
    }

    // MARK: Derived text

    var statusLine: String {
        if networkUnavailable { return "Network unavailable: check Wi-Fi." }
        guard !bulbs.isEmpty else { return "No bulbs found." }
        let reachable = bulbs.filter(\.isReachable).count
        let noun = bulbs.count == 1 ? "bulb" : "bulbs"
        let head = reachable == bulbs.count
            ? "\(bulbs.count) \(noun)."
            : "\(reachable) of \(bulbs.count) \(noun) reachable."
        switch partyState {
        case .off:
            if audioStartFailed { return "\(head) Glowbeat could not listen to system audio." }
            return "\(head) Party Mode is off."
        case .running:
            if audioPermission == .deniedOrSilent {
                return hasHeardAudioThisSession
                    ? "\(head) Waiting for music."
                    : "\(head) No audio is reaching Glowbeat."
            }
            return "\(head) Listening to system audio."
        case .paused(let reason):
            return "\(head) \(reason)"
        }
    }

    var banner: Banner? {
        if networkUnavailable { return .networkUnavailable }
        if case .paused(let reason) = partyState { return .partyPaused(reason) }
        if audioStartFailed { return .audioDenied }
        if partyState == .running, audioPermission == .deniedOrSilent, !hasHeardAudioThisSession {
            return .audioDenied
        }
        if bulbs.isEmpty { return .noBulbs }
        return nil
    }

    // MARK: The window's four panes

    /// Which pane the window is showing.
    var selectedPane: SidebarPane {
        settings.selectedPane
    }

    func setSelectedPane(_ pane: SidebarPane) {
        guard pane != settings.selectedPane else { return }
        settings.selectedPane = pane
        settingsStore.save(settings)
    }

    /// The live line under a sidebar title. Read rather than published: it is derived
    /// from things that are already observed, so the sidebar re-renders when one of them
    /// changes and never on its own.
    func sidebarStatus(for pane: SidebarPane) -> String {
        switch pane {
        case .bulbs:
            return SidebarStatus.bulbs(total: bulbs.count,
                                       on: bulbs.filter { $0.state?.isOn == true }.count)
        case .party:
            return SidebarStatus.party(state: partyState,
                                       effect: settings.effectKind,
                                       feel: settings.matchingPreset)
        case .scenes:
            return SidebarStatus.scenes(isRunning: isSceneRunning, kind: settings.sceneKind)
        case .colors:
            return SidebarStatus.colors(applied: appliedStillColor,
                                        brightness: settings.stillBrightness)
        case .schedule:
            return SidebarStatus.schedule(settings.schedule)
        }
    }

    // MARK: Names

    func displayName(for bulb: Bulb) -> String {
        let index = (orderedBulbs.firstIndex(where: { $0.id == bulb.id }) ?? 0) + 1
        return nameStore.name(for: bulb.id, fallback: "Bulb \(index)")
    }

    func setDisplayName(_ name: String, for bulb: Bulb) {
        nameStore.setName(name, for: bulb.id)
        // Republish the array so name observers re render.
        let snapshot = bulbs
        bulbs = snapshot
    }

    // MARK: Order

    /// The bulbs in the order the user arranged them: known ids in the stored order,
    /// anything new after them by bulb id.
    ///
    /// `bulbs` is already published in this order, because every discovery snapshot is
    /// sorted on the way in. This is still the property everything else reads, so that
    /// the list, the numbered names, Wave, Spread and the scenes to come all take the
    /// order from one place rather than from whatever the last snapshot happened to be.
    var orderedBulbs: [Bulb] {
        ordering.sorted(bulbs)
    }

    /// The reachable bulbs, in the user's order. What a command with no bulb, and what
    /// Party Mode, are aimed at.
    var reachableBulbs: [Bulb] {
        orderedBulbs.filter(\.isReachable)
    }

    /// Drag and drop from the bulb list. Writes the new order through, republishes the
    /// list so the rows move at once, and hands Party Mode the new order so a Wave that
    /// is already running starts traveling the way the list now reads.
    func moveBulbs(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = orderedBulbs
        ordered.move(fromOffsets: source, toOffset: destination)
        applyOrder(ordered)
    }

    /// Drag and drop from the bulb strip, where one tile is dropped onto another rather
    /// than into a gap between rows: the dragged bulb takes the place the tile it landed
    /// on was in, and everything between them shuffles up or down.
    ///
    /// The same one stored order the list writes, so the strip and the list can never
    /// disagree, and so the default names, which are positions, renumber in both at once.
    func moveBulb(withID id: String, toIndex destination: Int) {
        var ordered = orderedBulbs
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, destination), ordered.count - 1)
        guard to != from else { return }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: to)
        applyOrder(ordered)
    }

    /// Writes an arrangement through and tells everything that reads the order about it.
    private func applyOrder(_ ordered: [Bulb]) {
        ordering.apply(arrangement: ordered.map(\.id))
        bulbs = ordered
        // Also while a start is still unwinding: the state is still off at that point,
        // but the session's targets have already been captured, so a move made in that
        // window would otherwise never reach the engine.
        if partyState != .off || isPartyTransitioning {
            engine.updateBulbs(reachableBulbs)
            // Spread's fallback follows the position, so a reorder changes which band an
            // unassigned bulb is on. Resolving it again here is what keeps the room and
            // the rows on screen saying the same thing.
            pushSpreadAssignments()
        }
        // Color flow and Static both read the list order, so a scene that is already
        // running has to hear about a reorder as it happens.
        scenes.updateBulbs(reachableBulbs)
        lightModeEngine.updateBulbs(reachableBulbs)
        scheduleEngine.updateBulbs(reachableBulbs)
    }

    // MARK: Identify
    //
    // The sequence itself lives in `BulbIdentifier`. What stays here is the part that
    // needs the rest of the app: whether a flash may start, and which state it should
    // put the bulb back to.

    /// False while Party Mode is running or starting. A flash sends one shot power and
    /// color commands, which would fight the stream and leave the bulb wherever the
    /// collision landed, so the button is disabled rather than the commands queued.
    var canIdentify: Bool {
        partyState == .off && !isPartyTransitioning && !scenes.isRunning
    }

    var identifyingBulbIDs: Set<String> {
        identifier.flashingBulbIDs
    }

    func isIdentifying(_ bulb: Bulb) -> Bool {
        identifier.isFlashing(bulb.id)
    }

    /// About 1.5 s of white, off, white, off, and then the bulb as it was.
    func identify(_ bulb: Bulb) {
        guard canIdentify else { return }
        // The freshest report wins. The row hands over the bulb it drew itself from,
        // which may be a snapshot older than the last poll.
        let restore = bulbs.first { $0.id == bulb.id }?.state ?? bulb.state
        identifier.start(bulb, restore: restore)
    }

    var identifyStepInterval: TimeInterval {
        identifier.stepInterval
    }

    /// Only tests call this. See `BulbIdentifier.setStepInterval`.
    func setIdentifyStepInterval(_ seconds: TimeInterval) {
        identifier.setStepInterval(seconds)
    }

    // MARK: Bulb controls. A nil bulb means every bulb.

    func setPower(_ on: Bool, for bulb: Bulb?) {
        // The All row is the whole room, which is what a ramp is driving. Reaching for it
        // mid ramp means the user wants the room as they just set it, so the ramp stops
        // rather than arguing with them on the next tick. One bulb is not the room, so a
        // single row leaves the ramp alone.
        if bulb == nil {
            scheduleEngine.cancelRamp()
        }
        let targets = resolve(bulb)
        Task { [controller] in await controller.turn(on, bulbs: targets) }
    }

    func setBrightness(_ value: Int, for bulb: Bulb?) {
        let targets = resolve(bulb)
        Task { [controller] in await controller.setBrightness(value, bulbs: targets) }
    }

    func setColor(_ color: Effects.RGB, for bulb: Bulb?) {
        let targets = resolve(bulb)
        let govee = FrameBridge.goveeColor(from: color)
        Task { [controller] in await controller.setColor(govee, bulbs: targets) }
    }

    func setColorTemperature(kelvin: Int, for bulb: Bulb?) {
        let targets = resolve(bulb)
        Task { [controller] in await controller.setColorTemperature(kelvin: kelvin, bulbs: targets) }
    }

    private func resolve(_ bulb: Bulb?) -> [Bulb] {
        guard let bulb else { return reachableBulbs }
        return [bulb]
    }

    // MARK: Party Mode

    func setPartyModeEnabled(_ enabled: Bool) {
        if enabled {
            guard partyState == .off, !isPartyTransitioning else { return }
            audioStartFailed = false
            hasHeardAudioThisSession = false
            // Whatever a still color put on the bulbs is about to be painted over.
            dropAppliedStillColor()
            // A scene and Party Mode are mutually exclusive: both stream colors, and two
            // streams aimed at one bulb would fight.
            scenes.stop()
            // A wake or sleep ramp is a third claimant on the same bulbs, and it loses
            // the same way a scene does.
            scheduleEngine.cancelRamp()
            // A flash in flight would send one shot commands into the stream that is
            // about to start, so it is dropped rather than allowed to finish.
            identifier.cancelAll()
            isPartyTransitioning = true
            partySession &+= 1
            let session = partySession
            colorMismatches.removeAll()
            brightnessCheck.reset()
            // No baseline is guessed here. The first report of the session becomes one.
            baselines.removeAll()
            let targets = reachableBulbs
            let partyInterval = Self.partyPollInterval(forBulbCount: targets.count)
            let idleInterval = Self.idlePollInterval
            enqueueLifecycle { [poller] in
                await poller.updateBulbs(targets)
                await poller.setInterval(partyInterval)
            }
            // `start` suspends: it drains the previous session's commands and clears the
            // controller's send history before the first tick, and it opens the audio
            // tap on a background executor. Neither may block the UI.
            let assignments = resolvedSpreadAssignments
            partyTask = Task { [weak self, engine, settings] in
                do {
                    try await engine.start(bulbs: targets,
                                           effect: settings.effectKind,
                                           palette: settings.palette,
                                           gate: settings.partyGate,
                                           floor: settings.partyFloor,
                                           ceiling: settings.partyCeiling,
                                           updatesPerSecond: settings.maxUpdatesPerSecond,
                                           snap: settings.partySnap,
                                           fade: settings.partyFade,
                                           travelSpeed: settings.waveTravelSpeed,
                                           spreadAssignments: assignments,
                                           alwaysReacts: settings.alwaysReacts,
                                           confetti: settings.partyConfetti)
                    self?.finishTransition(session: session)
                } catch {
                    guard let self else { return }
                    self.finishTransition(session: session)
                    self.logger.error("Party Mode failed to start: \(String(describing: error), privacy: .public)")
                    self.audioStartFailed = true
                    self.audioPermission = .deniedOrSilent
                    await poller.setInterval(idleInterval)
                }
            }
        } else {
            // What the room ends on. The light mode wins when it has a white waiting, a
            // transition or a mode picked while the music played, because that white is
            // what the room is meant to be on once nothing else drives it; the settle
            // color would only flash before it. Otherwise the palette's dim base, as
            // spec 4.4 has always had it.
            switchPartyModeOff(settles: !lightModeTakesOverAfterParty)
        }
        updateLightModeSuspension()
    }

    /// Whether the light mode will paint the room the moment Party Mode lets go: it has a
    /// white waiting, and nothing else (a scene, a schedule ramp) is about to keep it
    /// suspended.
    private var lightModeTakesOverAfterParty: Bool {
        lightModeEngine.hasPendingApply && !scenes.isRunning && !scheduleState.isRunning
    }

    /// The one way Party Mode is switched off.
    ///
    /// `settles` false means whoever paints the room next is already known (the light
    /// mode's white, a still color) and the settle color would only flash before it.
    /// Whatever comes next waits on `engine.pendingCommands`, so it lands after Party
    /// Mode's last command instead of racing it on a chain of its own: the race that left
    /// Phil's room on the dim base rather than the Auto white (smoothness investigation
    /// H3, 2026-09-23).
    private func switchPartyModeOff(settles: Bool) {
        // `stop` is synchronous and safe mid transition, so an off tap always lands.
        partyTask?.cancel()
        partyTask = nil
        engine.stop(settle: settles)
        // Bumped so a start still unwinding cannot report its transition as the
        // current one, which would clear the flag out from under a later start.
        partySession &+= 1
        isPartyTransitioning = false
        baselines.removeAll()
        colorMismatches.removeAll()
        brightnessCheck.reset()
        audioStartFailed = false
        hasHeardAudioThisSession = false
        let idleInterval = Self.idlePollInterval
        enqueueLifecycle { [poller] in await poller.setInterval(idleInterval) }
    }

    func resumeParty() {
        guard case .paused = partyState, !isPartyTransitioning else { return }
        partySession &+= 1
        let session = partySession
        isPartyTransitioning = true
        colorMismatches.removeAll()
        // Resume sets full brightness again, and it has to be seen again before it counts.
        brightnessCheck.reset()
        // Whatever the phone did while Party Mode was paused is the new baseline, and
        // only a fresh report describes it. The first report after the resume defines it,
        // exactly as it does on a start.
        baselines.removeAll()
        partyTask = Task { [weak self, engine] in
            await engine.resume()
            self?.finishTransition(session: session)
        }
    }

    /// Clears the transition flag only if the transition that set it is still the current
    /// one. A start that was superseded before it unwound must not speak for its successor.
    private func finishTransition(session: Int) {
        guard session == partySession else { return }
        isPartyTransitioning = false
    }

    // MARK: Scenes
    //
    // The engine and the state live in `SceneCoordinator`. What stays here is what needs
    // the rest of the app: which bulbs a scene runs on, which palette and speed it starts
    // with, and that turning a scene on turns Party Mode off.

    var sceneState: SceneEngine.State {
        scenes.state
    }

    /// How far through Sunset, or `nil` for a scene with no end.
    var sceneProgress: Double? {
        scenes.progress
    }

    /// True while a scene is streaming. Party Mode's toggle and the Identify buttons read
    /// this, because all three want the same bulbs.
    var isSceneRunning: Bool {
        scenes.isRunning
    }

    func setSceneEnabled(_ enabled: Bool) {
        if enabled {
            // Party Mode first: it is the one holding the audio tap open.
            setPartyModeEnabled(false)
            dropAppliedStillColor()
            identifier.cancelAll()
            scheduleEngine.cancelRamp()
            scenes.start(bulbs: reachableBulbs,
                         kind: settings.sceneKind,
                         palette: settings.palette,
                         speed: settings.sceneSpeed,
                         singleColor: settings.sceneSingleColor)
        } else {
            scenes.stop()
        }
        updateLightModeSuspension()
    }

    /// Remembered whether or not anything is running, and swapped live when it is.
    func setScene(kind: SceneKind) {
        settings.sceneKind = kind
        settingsStore.save(settings)
        scenes.setScene(kind)
    }

    /// The window's two collapsible sections. Which ones are open is a layout choice, so
    /// it is remembered rather than reset on every launch, and it is what lets the window
    /// be made short enough for a small display.
    func setScenesSectionExpanded(_ expanded: Bool) {
        guard expanded != settings.showsScenesSection else { return }
        settings.showsScenesSection = expanded
        settingsStore.save(settings)
    }

    func setPartySectionExpanded(_ expanded: Bool) {
        guard expanded != settings.showsPartySection else { return }
        settings.showsPartySection = expanded
        settingsStore.save(settings)
    }

    /// Whether the Party panel's Advanced group is open. Remembered the same way the
    /// sections are: someone who has dialed in Snap and Fade should find them where they
    /// left them, and someone who never opens it should never see it.
    func setPartyAdvancedExpanded(_ expanded: Bool) {
        guard expanded != settings.showsPartyAdvanced else { return }
        settings.showsPartyAdvanced = expanded
        settingsStore.save(settings)
    }

    /// Static's single color mode. Remembered whatever scene is showing, so turning it on
    /// under Static and coming back to Static later finds it still on.
    func setSceneSingleColor(_ enabled: Bool) {
        guard enabled != settings.sceneSingleColor else { return }
        settings.sceneSingleColor = enabled
        settingsStore.save(settings)
        scenes.setSingleColor(enabled)
    }

    /// `persist` is false while the slider is being dragged, like the party gate: the
    /// scene follows the drag and the store is written when it ends.
    func setSceneSpeed(_ value: Double, persist: Bool = true) {
        settings.sceneSpeed = SceneKind.clampedSpeed(value)
        if persist {
            settingsStore.save(settings)
        }
        scenes.setSpeed(settings.sceneSpeed)
    }

    // MARK: Still colors
    //
    // The Colors pane: one color on the whole room, at one brightness, and then silence.
    // Phil, 2026-09-17: "individual static colors and a brightness slider so you can
    // easily pick a color, choose the brightness, and move on with life."
    //
    // Nothing here ticks and nothing here streams. Party Mode and the scenes repaint the
    // room many times a second, which is what makes them drivers and what makes them
    // mutually exclusive; a still color lands three commands and lets go, which is what
    // lets the phone, the Bulbs pane or the next Light transition have the room back
    // without an argument.

    /// Puts one color on every reachable bulb, at the brightness the pane's slider is on.
    ///
    /// Order matters and is guaranteed by one serial task: on, then the color, then the
    /// brightness. On first, because a color sent to a bulb that is off is a color nobody
    /// sees; brightness last, because the bulb applies it to whatever it is currently
    /// showing and sending it first would be a brightness applied to the old color.
    func applyStillColor(_ color: StillColor) {
        // The light mode is told first, and on purpose. Stopping Party Mode below
        // un-suspends it, and a transition it worked out while the music was playing
        // would be flushed at the room in that same turn, landing on top of the color the
        // user just asked for. Picking a color by hand is exactly the case the schedule
        // brief rules on: the color stands until the next real transition.
        lightModeEngine.userPickedAColor()
        // Party Mode first: it is the one holding the audio tap open. Then everything
        // else that wants these bulbs, in the order `setSceneEnabled` uses. No settle
        // color: this color is what the room ends on, and `sendStillColor` waits for
        // Party Mode's last command so nothing of Party Mode's lands on top of it.
        switchPartyModeOff(settles: false)
        updateLightModeSuspension()
        scenes.stop()
        scheduleEngine.cancelRamp()
        identifier.cancelAll()

        settings.stillColorID = color.id
        settingsStore.save(settings)
        appliedStillColor = color

        sendStillColor(color, brightness: settings.stillBrightness)
        updateLightModeSuspension()
    }

    /// The Colors pane's brightness slider.
    ///
    /// `persist` is false while it is being dragged, the same split every party slider
    /// uses: the room follows the finger and only the release is written to disk. Unlike
    /// those, the drag is rate limited, because each frame of this one is a real UDP
    /// command to every bulb rather than a number handed to an engine that is already
    /// ticking.
    func setStillBrightness(_ value: Double, persist: Bool = true) {
        settings.stillBrightness = StillColor.clampedBrightness(value)
        if persist {
            settingsStore.save(settings)
        }
        // Party Mode and the scenes are streaming colors at these bulbs, and a schedule
        // ramp is walking one. A brightness command in the middle of any of them is the
        // app fighting itself, so the slider keeps its value and sends nothing.
        guard !isDrivingBulbs, !scheduleState.isRunning else { return }

        let now = clock()
        if !persist {
            // The first frame of a drag always goes out: waiting out a window before
            // reacting is what makes a slider feel broken.
            guard now.timeIntervalSince(lastStillBrightnessSend)
                    >= Self.stillBrightnessSendInterval else { return }
        }
        lastStillBrightnessSend = now
        let targets = reachableBulbs
        guard !targets.isEmpty else { return }
        let percent = StillColor.brightnessPercent(settings.stillBrightness)
        Task { [controller] in
            await controller.setBrightness(percent, bulbs: targets)
        }
    }

    /// Stops claiming the room is wearing the still color, because something else just
    /// painted over it. The pick itself is left alone: the pane still rings the swatch,
    /// which is the last color the user chose and not a claim about the bulbs.
    private func dropAppliedStillColor() {
        appliedStillColor = nil
    }

    private func sendStillColor(_ color: StillColor, brightness: Double) {
        let targets = reachableBulbs
        guard !targets.isEmpty else { return }
        let percent = StillColor.brightnessPercent(brightness)
        lastStillBrightnessSend = clock()
        logger.log("Applying still color \(color.id, privacy: .public) at \(percent, privacy: .public)%.")
        // After whatever Party Mode still has on its way: its last tick goes out a slot at
        // a time, and a color of its landing after this one would be the room's last word.
        let partyCommands = engine.pendingCommands
        Task { [controller] in
            await partyCommands?.value
            await controller.turn(true, bulbs: targets)
            switch color.value {
            case .white(let kelvin):
                await controller.setColorTemperature(kelvin: kelvin, bulbs: targets)
            case .rgb(let rgb):
                await controller.setColor(FrameBridge.goveeColor(from: rgb), bulbs: targets)
            }
            await controller.setBrightness(percent, bulbs: targets)
        }
    }

    // MARK: Light mode and the schedule
    //
    // The engines live in `LightModeEngine` and `ScheduleEngine`. What stays here is the
    // part that needs the rest of the app: which bulbs, who is allowed to drive them, and
    // the settings the two engines are told about.

    var lightMode: LightMode {
        settings.lightMode
    }

    var scheduleSettings: ScheduleSettings {
        settings.schedule
    }

    /// The next wake or sleep the schedule will run, or nil when it is switched off.
    /// Read live rather than published, because it changes with the clock and nothing
    /// has to re-render until something else does.
    var nextScheduleEvent: ScheduleEngine.Event? {
        scheduleEngine.nextEvent(at: Date())
    }

    /// Whether Party Mode or a scene is holding the bulbs. A wake timer steps aside for
    /// this; a sleep timer stops it.
    var isDrivingBulbs: Bool {
        partyState != .off || isPartyTransitioning || scenes.isRunning
    }

    /// A deliberate choice, so the room takes the new white at once.
    func setLightMode(_ mode: LightMode) {
        guard mode != settings.lightMode else { return }
        settings.lightMode = mode
        settingsStore.save(settings)
        // A mode picked by hand repaints the whole room at once, so whatever still color
        // was on it is not on it any more.
        dropAppliedStillColor()
        lightModeEngine.setMode(mode, at: Date())
        lightModeStatus = lightModeEngine.status
    }

    /// How long Auto takes to move between the two whites. `persist` is false while the
    /// slider is being dragged, like the party sliders.
    func setShiftLength(minutes: Int, persist: Bool = true) {
        settings.shiftLengthMinutes = GlowbeatSettings.clampedShiftLengthMinutes(minutes)
        if persist {
            settingsStore.save(settings)
        }
        lightModeEngine.setShiftLength(minutes: settings.shiftLengthMinutes)
    }

    func setScheduleEnabled(_ enabled: Bool) {
        guard enabled != settings.schedule.isEnabled else { return }
        settings.schedule.isEnabled = enabled
        applyScheduleSettings()
    }

    func setWakeTime(_ time: TimeOfDay) {
        guard time != settings.schedule.wakeTime else { return }
        settings.schedule.wakeTime = time
        applyScheduleSettings()
    }

    func setSleepTime(_ time: TimeOfDay) {
        guard time != settings.schedule.sleepTime else { return }
        settings.schedule.sleepTime = time
        applyScheduleSettings()
    }

    func setWakeRamp(minutes: Int, persist: Bool = true) {
        settings.schedule.wakeRampMinutes = ScheduleSettings.clampedRampMinutes(minutes)
        applyScheduleSettings(persist: persist)
    }

    func setSleepRamp(minutes: Int, persist: Bool = true) {
        settings.schedule.sleepRampMinutes = ScheduleSettings.clampedRampMinutes(minutes)
        applyScheduleSettings(persist: persist)
    }

    func setWakeBrightness(_ percent: Int, persist: Bool = true) {
        settings.schedule.wakeBrightness = ScheduleSettings.clampedWakeBrightness(percent)
        applyScheduleSettings(persist: persist)
    }

    private func applyScheduleSettings(persist: Bool = true) {
        if persist {
            settingsStore.save(settings)
        }
        scheduleEngine.setSettings(settings.schedule)
    }

    /// The light mode never writes over anything else that is driving the bulbs. It
    /// remembers that it wanted to and applies once, when they let go.
    ///
    /// A white let go of here waits for anything Party Mode still has on its way, so it is
    /// the last thing the room hears rather than racing Party Mode's last tick.
    private func updateLightModeSuspension() {
        lightModeEngine.setSuspended(isDrivingBulbs || scheduleState.isRunning,
                                     after: engine.pendingCommands)
    }

    /// What the Light card says under its picker, and the one place that decides it, so
    /// the pane and the Settings tab cannot word it two different ways.
    var lightModeCaption: String {
        ScheduleFormatting.lightModeCaption(lightModeStatus)
    }

    /// Only tests call these two: whether a ramp or a shift reached the room is otherwise
    /// invisible until someone watches the bulbs.
    var lightModeKelvin: Int {
        lightModeEngine.kelvin
    }

    func reconcileScheduleNow() {
        scheduleEngine.reconcileNow()
    }

    // MARK: Settings

    func setEffect(_ kind: EffectKind) {
        settings.effectKind = kind
        settingsStore.save(settings)
        engine.setEffect(kind)
    }

    func setPalette(id: String) {
        settings.paletteID = Palette.palette(withID: id).id
        settingsStore.save(settings)
        engine.setPalette(settings.palette)
        // Scenes draw from the same palette, so the picker moves both.
        scenes.setPalette(settings.palette)
    }

    /// The one reaction control. `persist` is false while the marker is being dragged:
    /// the gate reaches the engine on every frame of the drag, because dialing it in
    /// against music you are listening to is the whole point, but the store is only
    /// written once the drag ends.
    ///
    /// There is no separate sensitivity any more. The engine derives the beat detector's
    /// sensitivity from this same value, so a marker low on the bar means the room reacts
    /// to everything and a marker high up means it reacts only to the loud parts.
    func setPartyGate(_ value: Double, persist: Bool = true) {
        settings.partyGate = min(1, max(0, value))
        if persist {
            settingsStore.save(settings)
        }
        engine.setGate(settings.partyGate)
    }

    /// Always react: the room reacts to every sound and the marker is left alone until
    /// the box is unticked. A checkbox is one deliberate click rather than a drag, so
    /// there is no live and commit split here; it is written through straight away.
    ///
    /// The guard is not a micro optimization, for the reason `setShowsMenuBarExtra`
    /// gives: `settings` is one observed property, so a redundant write re-runs every
    /// view that reads any setting.
    func setAlwaysReacts(_ on: Bool) {
        guard on != settings.alwaysReacts else { return }
        settings.alwaysReacts = on
        settingsStore.save(settings)
        engine.setAlwaysReacts(on)
    }

    /// How dark a bulb sits when nothing is happening. `persist` is false while the
    /// slider is being dragged, like the gate: the room follows the drag and the store is
    /// written once it ends. Raising the floor into the ceiling pushes the ceiling up
    /// rather than letting the range collapse.
    func setPartyFloor(_ value: Double, persist: Bool = true) {
        let range = GlowbeatSettings.brightnessRange(settingFloor: value,
                                                     ceiling: settings.partyCeiling)
        applyBrightnessRange(range, persist: persist)
    }

    /// How bright a bulb goes on a full hit. Lowering the ceiling into the floor pushes
    /// the floor down.
    func setPartyCeiling(_ value: Double, persist: Bool = true) {
        let range = GlowbeatSettings.brightnessRange(settingCeiling: value,
                                                     floor: settings.partyFloor)
        applyBrightnessRange(range, persist: persist)
    }

    /// How fast the lights jump on a hit. Live while dragging, saved on release, like the
    /// brightness sliders.
    func setPartySnap(_ value: Double, persist: Bool = true) {
        settings.partySnap = min(1, max(0, value))
        if persist {
            settingsStore.save(settings)
        }
        engine.setTiming(snap: settings.partySnap, fade: settings.partyFade)
    }

    /// How slowly the lights settle after a hit.
    func setPartyFade(_ value: Double, persist: Bool = true) {
        settings.partyFade = min(1, max(0, value))
        if persist {
            settingsStore.save(settings)
        }
        engine.setTiming(snap: settings.partySnap, fade: settings.partyFade)
    }

    /// Applies a feel: the four values behind the Advanced disclosure, under one name.
    ///
    /// It goes through the same four setters the sliders use, so the running engine hears
    /// every one of them live and nothing has to be restarted. Only the last one persists:
    /// `settings` is written whole, so one save carries all four, and a tap on a preset is
    /// one decision rather than four writes.
    ///
    /// Trigger Level, Always react, Travel, the effect and the palette are deliberately
    /// left alone. Order does not matter: every preset's two brightnesses are further
    /// apart than `minimumBrightnessSpan`, so neither one pushes the other.
    func applyPartyPreset(_ preset: PartyPreset) {
        setPartyFloor(preset.floor, persist: false)
        setPartyCeiling(preset.ceiling, persist: false)
        setPartySnap(preset.snap, persist: false)
        setPartyFade(preset.fade)
    }

    // MARK: The saved Advanced default

    /// Keeps the four Advanced values as they stand as the default Reset returns to.
    ///
    /// It is the only setting the user makes out of other settings, which is why it is a
    /// button rather than a control: there is nothing to drag, and nothing to persist
    /// until it is pressed.
    func saveAdvancedAsDefault() {
        let values = settings.advancedValues
        guard settings.savedAdvancedDefault != values else { return }
        settings.savedAdvancedDefault = values
        settingsStore.save(settings)
    }

    /// Puts the four Advanced values back to the saved default, or to Punchy when there
    /// is not one.
    ///
    /// Through the same four setters a feel goes through, for the same reason: the
    /// running engine hears every one of them live, nothing is restarted, and one save
    /// carries all four because `settings` is written whole.
    func resetAdvanced() {
        let values = settings.effectiveAdvancedDefault
        setPartyFloor(values.floor, persist: false)
        setPartyCeiling(values.ceiling, persist: false)
        setPartySnap(values.snap, persist: false)
        setPartyFade(values.fade)
    }

    /// Whether pressing Reset would move anything. False on a fresh install, which is
    /// what tells someone the four sliders are already on their default rather than
    /// leaving them to press a button and watch nothing happen.
    var canResetAdvanced: Bool {
        !settings.advancedValues.matches(settings.effectiveAdvancedDefault)
    }

    /// Whether pressing Save as default would store anything new. The same question as
    /// `canResetAdvanced` asked the other way round: when the sliders already are the
    /// default, there is nothing to keep.
    var canSaveAdvancedAsDefault: Bool {
        !settings.advancedValues.matches(settings.effectiveAdvancedDefault)
    }

    /// The timing the running session holds, and the brightness range it renders every
    /// frame against. Read by the tests, the way `partyEngineSpreadAssignment` is:
    /// whether a feel, a slider or a Reset actually reached the room is otherwise
    /// invisible until someone watches the bulbs.
    var partyEngineTiming: EffectTiming {
        engine.effectTiming
    }

    var partyEngineBrightnessRange: (floor: Double, ceiling: Double) {
        engine.renderedBrightnessRange
    }

    /// How fast Wave's colors travel from bulb to bulb, in bulbs per second. Live while
    /// dragging, saved on release, like Snap and Fade. Only Wave reads it, but it is kept
    /// and handed over whatever effect is running, so leaving Wave and coming back finds
    /// the speed the user set.
    func setWaveTravelSpeed(_ value: Double, persist: Bool = true) {
        settings.waveTravelSpeed = WaveEffect.clampedTravelSpeed(value)
        if persist {
            settingsStore.save(settings)
        }
        engine.setWaveTravelSpeed(settings.waveTravelSpeed)
    }

    /// Confetti: every bulb its own palette color, never matching its neighbors. One
    /// click rather than a drag, so it is written through and handed to the running
    /// effect at once, the way a Spread band is.
    func setPartyConfetti(_ on: Bool) {
        guard settings.partyConfetti != on else { return }
        settings.partyConfetti = on
        settingsStore.save(settings)
        engine.setConfetti(on)
    }

    /// Whether the running effect has confetti on. Read by the tests: whether the switch
    /// reached the room is otherwise invisible until someone watches the bulbs.
    var partyEngineConfetti: Bool {
        engine.effectConfetti
    }

    // MARK: Spread band assignment

    /// Which part of the music a bulb follows in Spread: the band the user put it on, or
    /// the round robin fallback for its place in the list, which is what Spread did
    /// before the choice existed.
    ///
    /// A bulb that is not in the list has no row and nothing to show, so bass is only
    /// there to keep the return type honest.
    func spreadGroup(for bulbID: String) -> SpreadGroup {
        if let raw = settings.spreadAssignments[bulbID], let group = SpreadGroup(rawValue: raw) {
            return group
        }
        let ordered = orderedBulbs
        guard let index = ordered.firstIndex(where: { $0.id == bulbID }) else { return .bass }
        return SpreadEffect.roundRobin(count: ordered.count)[index]
    }

    /// Puts one bulb on one band. A segment is one deliberate click rather than a drag,
    /// so there is no live and commit split here: it is written through and handed to the
    /// running effect straight away.
    func setSpreadGroup(_ group: SpreadGroup, for bulbID: String) {
        guard settings.spreadAssignments[bulbID] != group.rawValue else { return }
        settings.spreadAssignments[bulbID] = group.rawValue
        settingsStore.save(settings)
        pushSpreadAssignments()
    }

    /// The assignment the running Spread holds. Read by the tests: whether a click on a
    /// segment reached the room is otherwise invisible until someone watches the bulbs.
    var partyEngineSpreadAssignment: [SpreadGroup]? {
        engine.effectSpreadAssignment
    }

    /// Every bulb's band resolved in one map, chosen or fallen back, for the engine.
    ///
    /// The fallback is worked out here rather than left to the engine because the engine
    /// only ever sees the reachable bulbs: a bulb that is off at the wall would shift
    /// every fallback below it and the room would stop matching the rows on screen.
    private var resolvedSpreadAssignments: [String: SpreadGroup] {
        let ordered = orderedBulbs
        let fallback = SpreadEffect.roundRobin(count: ordered.count)
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, bulb in
            let stored = settings.spreadAssignments[bulb.id].flatMap(SpreadGroup.init(rawValue:))
            return (bulb.id, stored ?? fallback[index])
        })
    }

    private func pushSpreadAssignments() {
        engine.setSpreadAssignments(resolvedSpreadAssignments)
    }

    private func applyBrightnessRange(_ range: (floor: Double, ceiling: Double),
                                      persist: Bool) {
        settings.partyFloor = range.floor
        settings.partyCeiling = range.ceiling
        if persist {
            settingsStore.save(settings)
        }
        engine.setBrightnessRange(floor: range.floor, ceiling: range.ceiling)
    }

    /// Settings is the only caller. Turning the setting on also asks for the item back,
    /// which is what lets someone who was evicted try again after making room.
    ///
    /// The guard is not a micro optimization. `@Observable` invalidates on every write,
    /// equal or not, and `settings` is one property, so a redundant write here re-runs
    /// the whole `App` body and everything that reads any setting.
    func setShowsMenuBarExtra(_ shows: Bool) {
        guard shows != settings.showsMenuBarExtra else { return }
        settings.showsMenuBarExtra = shows
        settingsStore.save(settings)
        setMenuBarExtraInserted(shows)
    }

    /// What macOS did, reported back through `MenuBarExtra(isInserted:)`.
    ///
    /// A full menu bar means the item is evicted the moment it is added, and SwiftUI says
    /// so by writing `false`. Recording it is what makes the scene converge: the binding
    /// then reads `false` too and SwiftUI stops adding an item the system keeps throwing
    /// away. The stored setting is deliberately left alone, so nothing the user chose is
    /// undone by a menu bar that happened to be full.
    func setMenuBarExtraInserted(_ inserted: Bool) {
        guard inserted != isMenuBarExtraInserted else { return }
        isMenuBarExtraInserted = inserted
    }

    func setLaunchesAtLogin(_ launches: Bool) {
        do {
            if launches {
                try loginItems.register()
            } else {
                try loginItems.unregister()
            }
        } catch {
            logger.error("Launch at login change failed: \(String(describing: error), privacy: .public)")
        }
        // The service is the truth on both paths, not only when the call threw:
        // `register()` can succeed into `.requiresApproval` rather than `.enabled`, and
        // the setting must never claim more than macOS actually did.
        settings.launchesAtLogin = loginItems.status == .enabled
        settingsStore.save(settings)
    }

    /// What macOS says about the login item right now. Settings reads this for the note
    /// under the toggle, so the one process hop lives behind the same seam.
    var loginItemStatus: LoginItemStatus {
        loginItems.status
    }

    func setRescanInterval(_ seconds: TimeInterval) {
        settings.rescanInterval = GlowbeatSettings.clampedRescanInterval(seconds)
        settingsStore.save(settings)
        let interval = settings.rescanInterval
        enqueueLifecycle { [discovery] in await discovery.setRescanInterval(interval) }
    }

    /// The Settings slider, which is the most a bulb may be sent a second rather than the
    /// rate: the room's send budget lowers it further when there are many bulbs.
    func setMaxUpdatesPerSecond(_ value: Int) {
        settings.maxUpdatesPerSecond = GlowbeatSettings.clampedUpdatesPerSecond(value)
        settingsStore.save(settings)
        engine.setUpdatesPerSecond(settings.maxUpdatesPerSecond)
    }

    /// The rate Party Mode streams each bulb at in this room: the slider, lowered to the
    /// room's share of `StreamRateLimiter.roomBudgetPerSecond`. What Settings shows next
    /// to the slider when it is lower than the slider.
    var effectivePartyUpdatesPerSecond: Int {
        StreamRateLimiter.perBulbSendsPerSecond(ceiling: settings.maxUpdatesPerSecond,
                                                bulbCount: reachableBulbs.count)
    }

    /// The status poll cadence in force. Read by the tests.
    func statusPollInterval() async -> TimeInterval {
        await poller.pollInterval
    }

    func completeFirstRun() {
        settings.hasCompletedFirstRun = true
        settingsStore.save(settings)
    }

    // MARK: Incoming updates

    private func applyDiscovered(_ snapshot: [Bulb]) {
        bulbs = snapshot
        // The snapshot arrives already sorted by the stored order, so recording the ids
        // the order has never seen keeps it complete without disturbing what is in it.
        ordering.noteDiscovered(snapshot.map(\.id))
        let targets = snapshot.filter(\.isReachable)
        // `start(bulbs:)` sets the list and arms the loops only once, so calling it on
        // every snapshot is how the poller both learns about new bulbs and gets armed.
        enqueueLifecycle { [poller] in await poller.start(bulbs: targets) }
        if partyState != .off {
            engine.updateBulbs(targets)
            pushSpreadAssignments()
            // The room changed size, so its share of the poll budget did too.
            let partyInterval = Self.partyPollInterval(forBulbCount: targets.count)
            enqueueLifecycle { [poller] in await poller.setInterval(partyInterval) }
        }
        scenes.updateBulbs(targets)
        lightModeEngine.updateBulbs(targets)
        scheduleEngine.updateBulbs(targets)
    }

    private func applyStatus(_ update: BulbStatusUpdate) {
        if let index = bulbs.firstIndex(where: { $0.id == update.bulbID }) {
            bulbs[index].state = update.state
            bulbs[index].isReachable = true
        }
        // Feed the reported state back into discovery so the bulb rows, which are
        // rebuilt from discovery snapshots, show live power, brightness and color.
        enqueueLifecycle { [discovery] in
            await discovery.apply(state: update.state, forBulbID: update.bulbID)
        }
        guard partyState == .running else { return }

        let session = partySession
        // The first report of the session for this bulb is the baseline, not a finding.
        // Both the app and a phone may have touched this bulb before the session began,
        // and neither is worth pausing over now.
        let isBaseline = baselines[update.bulbID] == nil
        if isBaseline {
            baselines[update.bulbID] = PartyBaseline(power: update.state.isOn,
                                                     brightness: update.state.brightness)
        }
        let baseline = baselines[update.bulbID] ?? PartyBaseline()
        Task { [weak self, controller, changeDetector] in
            // Judged against what the bulb had been sent by the time it answered, not by
            // the time this runs, and over seconds rather than the last few colors: the
            // bulb may be fading, a datagram or two behind, or answering late.
            let sent = await controller.sentColorHistory(for: update.bulbID, asOf: update.receivedAt)
            let sentPower = await controller.lastSentPower(for: update.bulbID)
            let sentBrightness = await controller.lastSentBrightness(for: update.bulbID)
            guard let self, self.partySession == session, self.partyState == .running else { return }
            // Every report counts towards showing the brightness Party Mode set, the
            // baseline included; only a bulb that has shown it is judged against it.
            let expectedBrightness = self.brightnessCheck.expectation(
                for: update.bulbID,
                reported: update.state.brightness,
                sent: sentBrightness,
                baseline: baseline.brightness)
            guard !isBaseline else { return }
            let expectation = ExternalChangeDetector.Expectation(
                expectedPower: sentPower ?? baseline.power,
                expectedBrightness: expectedBrightness,
                recentColors: sent.map(\.color))
            let finding = changeDetector.evaluate(reported: update.state, expectation: expectation)
            if finding != .color {
                self.colorMismatches[update.bulbID] = nil
            }
            guard let reason = finding.reason else { return }
            if finding == .color {
                var run = self.colorMismatches[update.bulbID] ?? ExternalChangeDetector.ColorMismatchRun()
                run.add(update.state.color)
                self.colorMismatches[update.bulbID] = run
                guard run.isTakeover else { return }
            }
            self.engine.pause(reason: reason)
        }
    }
}
