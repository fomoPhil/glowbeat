import AudioTap
import Effects
import Foundation
import GoveeLAN
import OSLog

/// Runs Party Mode: audio frames in, deduped `colorwc` sends out.
///
/// Lifecycle follows spec section 4.4. Switching off sends one final color at the
/// palette's dim base rather than restoring the pre party color, because jumping back
/// would look worse than settling, unless the app already knows who paints the room next
/// (the light mode's white, a still color) and hands it over instead (`stop(settle:)`).
///
/// Every command this engine issues goes through one serial chain, so a color computed
/// on an earlier tick can never overtake a later one and the settle color on stop is
/// always the last thing a bulb hears.
@MainActor
final class PartyEngine {

    enum State: Equatable {
        case off
        case running
        case paused(reason: String)
    }

    private(set) var state: State = .off
    private(set) var level: Float = 0
    /// The tap's own read on whether macOS is really giving us audio. Party Mode keeps
    /// running when this turns to `deniedOrSilent`, because silence is a normal thing for
    /// a Mac to be playing. The UI decides whether to explain it.
    private(set) var permission: AudioTapPermission = .unknown

    var onStateChange: (@MainActor (State) -> Void)?
    var onLevelChange: (@MainActor (Float) -> Void)?
    var onPermissionChange: (@MainActor (AudioTapPermission) -> Void)?

    private let controller: BulbController
    private let frameSource: any AudioFrameSource
    /// The only thing allowed to call `frameSource.start()` and `frameSource.stop()`.
    private let audioLifecycle: AudioLifecycle
    private let tickSource: any TickSource
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "PartyEngine")

    private var bulbs: [Bulb] = []
    private var palette: Palette = .party
    private var effect: any Effect = EffectKind.pulse.makeEffect()
    private var detector = BeatDetector(
        sensitivity: GlowbeatSettings.derivedSensitivity(forGate: GlowbeatSettings.defaults.partyGate))
    private var autoGain = AutoGain()
    private var gate = PartyGate(threshold: GlowbeatSettings.defaults.partyGate)
    /// Where the user left the marker, which is not always what the gate is running at:
    /// Always react runs the gate at 0 and leaves this alone, so unticking the box puts
    /// the room straight back without the user having to find their old position again.
    private(set) var gateMarker = GlowbeatSettings.defaults.partyGate
    /// Whether the marker is being ignored. Live: ticking the box retunes the gate and
    /// the detector on the next tick and restarts nothing.
    private(set) var alwaysReacts = GlowbeatSettings.defaults.alwaysReacts
    /// The user's Snap and Fade, shared by the gate and every effect.
    private(set) var timing = EffectTiming.from(snap: GlowbeatSettings.defaults.partySnap,
                                                fade: GlowbeatSettings.defaults.partyFade)
    /// The user's Travel, in bulbs per second. Held here rather than only inside the
    /// running effect, exactly as `timing` is, so switching effect and coming back to
    /// Wave does not quietly throw it away.
    private(set) var waveTravelSpeed = GlowbeatSettings.defaults.waveTravelSpeed
    /// Which part of the music each bulb follows in Spread, by bulb id. Held here rather
    /// than only inside the running effect, exactly as `waveTravelSpeed` is, so switching
    /// effect and coming back to Spread does not quietly throw the user's choice away.
    ///
    /// By id rather than by position, because the effect wants an array in the room's
    /// order and the room can be rearranged: keeping the map and laying it out on demand
    /// is what makes a band belong to a bulb rather than to a slot.
    private(set) var spreadAssignments: [String: SpreadGroup] = [:]
    /// Whether every bulb gets its own palette color. Held here as well as in the running
    /// effect, exactly as `waveTravelSpeed` is, so a new effect is handed it.
    private(set) var confetti = GlowbeatSettings.defaults.partyConfetti
    /// The Darkest and Brightest sliders. Every effect reports an intensity from 0 to 1
    /// and this is the range that intensity is mapped into, so a room can be kept lit and
    /// still show every beat.
    private var brightnessFloor = GlowbeatSettings.defaults.partyFloor
    private var brightnessCeiling = GlowbeatSettings.defaults.partyCeiling
    private var deduper = ColorDeduper()
    /// Takes the room down to calm over the Fade when the gate shuts, rather than in one
    /// tick. Never reset: a session that starts or resumes has been quiet long enough that
    /// there is nothing lit left to glide from.
    private var glide = GateGlide()
    /// The Settings slider: the most a bulb may be sent a second. The rate the session
    /// really runs at is `streamRate`, which this only caps.
    private var updatesPerSecond = StreamRateLimiter.defaultSendsPerSecond
    /// What the tick source and the controller were last told, so a bulb joining a room
    /// that keeps the same rate does not restart the tick for nothing.
    private var appliedStreamRate = StreamRateLimiter.defaultSendsPerSecond

    private var pendingFrames: [AudioTap.AudioFrame] = []
    private var latestFrame: Effects.AudioFrame?
    /// The time of the last frame the gate saw, so the smoothing measures the audio's
    /// own clock rather than how often the engine happened to tick.
    private var lastGatedFrameTime: TimeInterval?
    private var frameTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var sendChain: Task<Void, Never>?

    /// `start` and `resume` suspend partway through. These let `stop` and `pause` land
    /// during that window instead of being lost or, worse, overwritten by a transition
    /// that finishes after them.
    private var isTransitioning = false
    private var transitionGeneration = 0
    private var pendingPauseReason: String?

    /// Four seconds of frames at 50 fps. Anything older is not worth catching up on.
    private static let maximumPendingFrames = 200

    /// Where the opt-in diagnostic trace comes from. Asked once per session; with the
    /// `partyTrace` defaults key off it answers nil and the session runs exactly as it
    /// would with no factory at all.
    private let traceFactory: PartyTraceFactory?
    /// The running session's trace, when one was asked for.
    private var trace: PartyTraceSession?
    /// When the previous traced tick began, for the trace's `dt_ms`. Only kept while a
    /// trace runs.
    private var lastTraceTickUptime: TimeInterval?

    init(controller: BulbController,
         frameSource: any AudioFrameSource,
         tickSource: any TickSource,
         traceFactory: PartyTraceFactory? = nil) {
        self.controller = controller
        self.frameSource = frameSource
        self.audioLifecycle = AudioLifecycle(source: frameSource)
        self.tickSource = tickSource
        self.traceFactory = traceFactory
    }

    deinit {
        // The command chain is deliberately left alone: a settle color queued by `stop`
        // has to reach the bulbs even if the engine is released straight afterwards.
        frameTask?.cancel()
        permissionTask?.cancel()
    }

    // MARK: Lifecycle

    /// Asynchronous because the controller's send history has to be cleared, and the
    /// clearing observed, before the first tick can send anything. The phone takeover
    /// detector reads that history the moment Party Mode is on, and a history left over
    /// from the previous session would read as someone grabbing the Govee app.
    func start(bulbs: [Bulb],
               effect: EffectKind,
               palette: Palette,
               gate: Double,
               floor: Double,
               ceiling: Double,
               updatesPerSecond: Int,
               snap: Double = GlowbeatSettings.defaults.partySnap,
               fade: Double = GlowbeatSettings.defaults.partyFade,
               travelSpeed: Double = GlowbeatSettings.defaults.waveTravelSpeed,
               spreadAssignments: [String: SpreadGroup] = [:],
               alwaysReacts: Bool = GlowbeatSettings.defaults.alwaysReacts,
               confetti: Bool = GlowbeatSettings.defaults.partyConfetti) async throws {
        guard state == .off, !isTransitioning else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        isTransitioning = true
        pendingPauseReason = nil
        defer { isTransitioning = false }

        self.bulbs = bulbs
        self.palette = palette
        self.effect = effect.makeEffect()
        self.detector = BeatDetector(sensitivity: GlowbeatSettings.derivedSensitivity(forGate: gate))
        self.autoGain.reset()
        self.gate = PartyGate(threshold: gate)
        self.gateMarker = min(1, max(0, gate))
        self.alwaysReacts = alwaysReacts
        self.applyReaction()
        self.setTiming(snap: snap, fade: fade)
        self.setWaveTravelSpeed(travelSpeed)
        self.setSpreadAssignments(spreadAssignments)
        self.setConfetti(confetti)
        self.setBrightnessRange(floor: floor, ceiling: ceiling)
        self.deduper.reset()
        self.updatesPerSecond = StreamRateLimiter.clampSendsPerSecond(updatesPerSecond)
        self.appliedStreamRate = streamRate
        self.pendingFrames.removeAll(keepingCapacity: true)
        self.latestFrame = nil
        self.lastGatedFrameTime = nil

        // Let the previous session's settle color finish first, or it would repopulate
        // the history straight after this clears it.
        await sendChain?.value
        guard generation == transitionGeneration else { return }
        sendChain = nil
        await controller.clearSendHistory()
        guard generation == transitionGeneration else { return }
        await controller.setMaxStreamedSendsPerSecond(appliedStreamRate)
        guard generation == transitionGeneration else { return }
        beginTrace()

        do {
            try await audioLifecycle.start()
        } catch {
            logger.error("Party Mode could not start the audio tap: \(String(describing: error), privacy: .public)")
            endTrace(reason: "the audio tap did not open")
            throw error
        }
        // Opening the tap suspends, so a stop may have landed while it was opening. That
        // stop queued its own close behind this open on the same actor, so the tap is
        // already being shut: all this has to do is not declare the engine running.
        guard generation == transitionGeneration else { return }

        // Only once the tap is open: a session that never starts must not brighten a room
        // nobody asked it to touch.
        setFullBrightness(on: self.bulbs)
        startObserving()
        startTicking(at: appliedStreamRate)
        setState(.running)
        applyPendingPause()
    }

    /// Switches Party Mode off and settles the room.
    ///
    /// `settle` false leaves the room to whoever paints it next (the light mode's white,
    /// a still color) instead of sending the palette's dim base, which would only flash
    /// before it. Either way anything the rate limiter still holds is released first, and
    /// whatever comes next waits on `pendingCommands`, so it lands after Party Mode's last
    /// command rather than racing it on a chain of its own.
    func stop(settle: Bool = true) {
        // `isTransitioning` keeps a stop that lands mid `start` or mid `resume` from being
        // dropped. The transition sees the bumped generation and bails out.
        guard state != .off || isTransitioning else { return }
        transitionGeneration &+= 1
        pendingPauseReason = nil
        tickSource.stop()
        // The frame reading task is never canceled: canceling a task parked in
        // `AsyncStream.next()` finishes that stream for good, and the tap hands out one
        // stream for its whole life, so Party Mode would work exactly once per launch.
        // Stopping the source is enough, and `enqueue` drops anything still in flight.
        // Closing the tap is asynchronous for the same reason opening it is, and the
        // lifecycle actor keeps it ordered behind any open still running.
        Task { [audioLifecycle] in await audioLifecycle.stop() }
        pendingFrames.removeAll(keepingCapacity: true)
        latestFrame = nil
        lastGatedFrameTime = nil
        gate.reset()
        level = 0
        onLevelChange?(0)

        // One final settle color so the room does not stay mid flash. The flush releases
        // anything the rate limiter is still holding, then the dim base goes out as a one
        // shot so it is repeated the way every other deliberate command is.
        //
        // The bulbs' own brightness, which `start` set to 100, is deliberately not put
        // back. The only record of what it was is a status report from before the session,
        // possibly a minute stale, and the one before that the app never saw; restoring a
        // guess would dim the settle color, or whatever the light mode puts up next, to a
        // level nobody chose. Spec 4.4 has the same rule for the color: settle, not restore.
        let dimBase = FrameBridge.goveeColor(from: palette.dimBase)
        let targets = bulbs
        enqueueCommand { controller in
            await controller.flushStreamed(bulbs: targets)
            guard settle else { return }
            await controller.setColor(dimBase, bulbs: targets)
        }
        endTrace(reason: settle ? "stopped" : "stopped and handed over")
        setState(.off)
    }

    /// Everything Party Mode has queued for the bulbs and not yet sent: the last tick's
    /// colors, going out a slot at a time, and the flush and settle color from a stop.
    /// Whatever paints the room after Party Mode waits on this.
    var pendingCommands: Task<Void, Never>? {
        sendChain
    }

    /// Phone takeover. The tap keeps running so Resume is instant.
    func pause(reason: String) {
        // A pause that lands mid `start` or mid `resume` is held until that transition
        // finishes, so the engine ends up paused with a live tap rather than ignoring it.
        if isTransitioning {
            pendingPauseReason = reason
            return
        }
        performPause(reason: reason)
    }

    /// Asynchronous for the same reason as `start`: whatever the phone did to the bulbs
    /// while Party Mode was paused must be out of the send history before ticks resume.
    func resume() async {
        guard case .paused = state, !isTransitioning else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        isTransitioning = true
        pendingPauseReason = nil
        defer { isTransitioning = false }

        deduper.reset()
        detector.reset()
        effect.reset()
        gate.reset()
        pendingFrames.removeAll(keepingCapacity: true)
        latestFrame = nil
        lastGatedFrameTime = nil

        await sendChain?.value
        guard generation == transitionGeneration else { return }
        sendChain = nil
        await controller.clearSendHistory()
        guard generation == transitionGeneration else { return }

        trace?.event("resume", detail: "")
        lastTraceTickUptime = nil
        // Whatever the phone did to the brightness while paused, Resume is the user asking
        // for Party Mode again, and Party Mode's range assumes a bulb at 100.
        setFullBrightness(on: bulbs)
        startTicking(at: appliedStreamRate)
        setState(.running)
        applyPendingPause()
    }

    // MARK: Live adjustments

    func updateBulbs(_ bulbs: [Bulb]) {
        let known = Set(self.bulbs.map(\.id))
        let removed = known.subtracting(bulbs.map(\.id))
        for id in removed {
            deduper.forget(id)
        }
        // A bulb back on the network mid session, off a smart switch at its own stored
        // brightness, joins at 100 like the rest. Paused, it waits for Resume, which sets
        // every bulb.
        if state == .running {
            setFullBrightness(on: bulbs.filter { !known.contains($0.id) })
        }
        self.bulbs = bulbs
        trace?.updateBulbs(bulbs)
        // Spread renders an array in the room's order, so a bulb arriving, leaving or
        // being dragged up the list has to be laid out again from the id map.
        applySpreadAssignmentToEffect()
        applyStreamRate()
    }

    /// A new effect is built from scratch, so it starts on the Effects package's own
    /// timing and no gate at all. Both have to be handed to it here, exactly as `start`
    /// does, or switching effect mid session would quietly throw the user's Snap and
    /// Fade away and drop the room back onto the package's defaults rather than Punchy's.
    func setEffect(_ kind: EffectKind) {
        effect = kind.makeEffect()
        applyGateToEffect()
        effect.setTiming(timing)
        applyTravelSpeedToEffect()
        applySpreadAssignmentToEffect()
        effect.setConfetti(confetti)
        deduper.reset()
        trace?.event("effect", detail: kind.rawValue)
    }

    func setPalette(_ palette: Palette) {
        self.palette = palette
        deduper.reset()
        trace?.event("palette", detail: palette.id)
    }

    /// Live, so dragging the Trigger Level marker changes the room as it moves. The
    /// smoothed level and the open or closed state are kept: the next frame judges the
    /// level already in hand against the new threshold.
    ///
    /// The marker is the whole reaction control, so it moves the beat detector with it:
    /// low down the detector fires on everything, high up only on the loud hits. Deriving
    /// it here rather than at the caller is what stops the two ever disagreeing.
    ///
    /// While Always react is on the marker is still remembered, and still nothing: the
    /// value is stored and applied the moment the box is unticked.
    func setGate(_ value: Double) {
        gateMarker = min(1, max(0, value))
        applyReaction()
        traceReaction()
    }

    /// Live, like the marker: ticking Always react opens the gate on the next tick and
    /// unticking it hands the room back to wherever the marker was left. Nothing is
    /// reset, so the box can be tried mid track without the effect starting over.
    func setAlwaysReacts(_ on: Bool) {
        alwaysReacts = on
        applyReaction()
        traceReaction()
    }

    private func traceReaction() {
        guard let trace else { return }
        trace.event("reaction", detail: String(format: "marker %.3f always %d gate %.3f sensitivity %.3f",
                                               gateMarker, alwaysReacts ? 1 : 0,
                                               gate.threshold, detector.sensitivity))
    }

    /// What the gate is actually judging against right now: the marker, or 0 while
    /// Always react is on. Read by the tests, like `beatSensitivity`, because the marker
    /// and the threshold parting company is the whole of this feature.
    var effectiveGate: Double {
        gate.threshold
    }

    /// The gate and the detector in one place, so the two can never disagree about
    /// whether the marker is being used.
    private func applyReaction() {
        gate.threshold = alwaysReacts ? 0 : gateMarker
        detector.sensitivity = alwaysReacts
            ? GlowbeatSettings.alwaysReactsSensitivity
            : GlowbeatSettings.derivedSensitivity(forGate: gateMarker)
        applyGateToEffect()
    }

    /// What the detector is running at right now. Read by the tests, which is the only
    /// way to see a value that is otherwise derived and applied in one step.
    var beatSensitivity: Double {
        detector.sensitivity
    }

    /// The timing the running effect actually holds, as opposed to the one the engine
    /// was last told about. Read by the tests: the two drifting apart is exactly the bug
    /// that made switching effect mid session lose the user's Snap and Fade.
    var effectTiming: EffectTiming {
        effect.timing
    }

    /// The travel speed the running Wave actually holds, or nil when another effect is
    /// running. Read by the tests, the same way `effectTiming` is: the engine's copy and
    /// the effect's copy drifting apart is the bug worth catching.
    var effectWaveTravelSpeed: Double? {
        (effect as? WaveEffect)?.bulbsPerSecond
    }

    /// The brightness range every frame is rendered through. Read by the tests, like
    /// `effectTiming`: a feel that reached the engine's timing but not its brightnesses
    /// would light the room at the wrong two ends with nothing on screen to show it.
    var renderedBrightnessRange: (floor: Double, ceiling: Double) {
        (brightnessFloor, brightnessCeiling)
    }

    /// Volume driven effects map the level through the same threshold, so they start
    /// from black at the gate rather than from wherever the gate happens to sit.
    private func applyGateToEffect() {
        effect.setGate(gate.threshold)
    }

    /// Live, like Snap and Fade: dragging Travel changes how fast the colors cross the
    /// room on the next tick without restarting anything.
    ///
    /// Travel belongs to one effect rather than to the `Effect` protocol, so this is the
    /// one place that knows Wave by name.
    func setWaveTravelSpeed(_ value: Double) {
        waveTravelSpeed = WaveEffect.clampedTravelSpeed(value)
        applyTravelSpeedToEffect()
        trace?.event("travel", detail: String(format: "%.2f bulbs/s", waveTravelSpeed))
    }

    private func applyTravelSpeedToEffect() {
        guard var wave = effect as? WaveEffect else { return }
        wave.setTravelSpeed(waveTravelSpeed)
        effect = wave
    }

    /// Live, like Travel: putting a bulb on Bass changes the room on the next tick
    /// without restarting anything.
    ///
    /// Spread belongs to one effect rather than to the `Effect` protocol, so this and
    /// `setWaveTravelSpeed` are the two places that know an effect by name.
    func setSpreadAssignments(_ assignments: [String: SpreadGroup]) {
        spreadAssignments = assignments
        applySpreadAssignmentToEffect()
    }

    /// The assignment the running Spread actually holds, or nil when another effect is
    /// running. Read by the tests, the same way `effectWaveTravelSpeed` is: the engine's
    /// map and the effect's array drifting apart is the bug worth catching.
    var effectSpreadAssignment: [SpreadGroup]? {
        (effect as? SpreadEffect)?.assignment
    }

    private func applySpreadAssignmentToEffect() {
        guard var spread = effect as? SpreadEffect else { return }
        spread.setAssignment(orderedSpreadAssignment())
        effect = spread
    }

    /// Live, like Travel: the room fades apart into its own colors, or back together, from
    /// the next tick, with nothing restarted. Unlike Travel it belongs to every effect,
    /// so it goes through the `Effect` protocol rather than a cast.
    func setConfetti(_ on: Bool) {
        confetti = on
        effect.setConfetti(on)
        trace?.event("confetti", detail: on ? "on" : "off")
    }

    /// Whether the running effect actually has confetti on. Read by the tests, the same
    /// way `effectWaveTravelSpeed` is: the engine's copy and the effect's drifting apart
    /// is the bug worth catching.
    var effectConfetti: Bool {
        effect.confetti
    }

    /// The id map laid out in the room's order. A bulb nobody has chosen for, which is
    /// what a bulb bought today looks like, takes the round robin for wherever it landed
    /// rather than going dark.
    private func orderedSpreadAssignment() -> [SpreadGroup] {
        let fallback = SpreadEffect.roundRobin(count: bulbs.count)
        return bulbs.enumerated().map { index, bulb in
            spreadAssignments[bulb.id] ?? fallback[index]
        }
    }

    /// Live, like the gate: dragging Snap or Fade retunes the gate and the running effect
    /// on the next tick without restarting anything.
    func setTiming(snap: Double, fade: Double) {
        timing = EffectTiming.from(snap: snap, fade: fade)
        gate.setTiming(timing)
        effect.setTiming(timing)
        trace?.event("timing", detail: String(format: "attack_s %.3f release_s %.3f",
                                              timing.attack, timing.release))
    }

    /// Live, so dragging Darkest or Brightest changes the room as it moves. The range is
    /// read on the next tick, so nothing has to be reset for it to take effect.
    func setBrightnessRange(floor: Double, ceiling: Double) {
        let range = GlowbeatSettings.brightnessRange(settingFloor: floor, ceiling: ceiling)
        brightnessFloor = range.floor
        brightnessCeiling = range.ceiling
        trace?.event("range", detail: String(format: "floor %.3f ceiling %.3f",
                                             brightnessFloor, brightnessCeiling))
    }

    /// The Settings slider, which is a ceiling: the room's budget may lower it further.
    func setUpdatesPerSecond(_ value: Int) {
        let clamped = StreamRateLimiter.clampSendsPerSecond(value)
        guard clamped != updatesPerSecond else { return }
        updatesPerSecond = clamped
        applyStreamRate()
    }

    // MARK: The bulbs' own brightness

    /// Puts `targets` at their own full brightness, through the command chain so it lands
    /// before the first color any later tick sends them.
    ///
    /// Party Mode does its dimming in the colors it streams, Darkest to Brightest, and that
    /// only means what it says on a bulb whose own brightness is 100. The Colors pane, the
    /// All bulbs slider, the menu bar slider and the schedule all set the bulb's own
    /// brightness, so a room left at 30 percent used to run a whole session at 30 percent
    /// of Brightest (Phil, 2026-09-23: "the bulbs rarely reach actual 100%"). A one shot,
    /// so it is repeated the way every deliberate command is; the takeover check waits
    /// for a bulb to show it before judging it (`ExternalChangeDetector.BrightnessCheck`).
    private func setFullBrightness(on targets: [Bulb]) {
        guard !targets.isEmpty else { return }
        enqueueCommand { controller in
            await controller.setBrightness(100, bulbs: targets)
        }
    }

    // MARK: The room's send budget

    /// The rate each bulb streams at: the Settings slider, lowered so the whole room stays
    /// inside `StreamRateLimiter.roomBudgetPerSecond`. Six bulbs at ten a second, ten at
    /// six, fifteen at four. The engine ticks at this rate too, so it never works out
    /// colors the rate limiter would only throw away.
    var streamRate: Int {
        StreamRateLimiter.perBulbSendsPerSecond(ceiling: updatesPerSecond, bulbCount: bulbs.count)
    }

    /// Hands a new rate to the controller and the tick source, live. Called whenever the
    /// ceiling or the room changes; a change that leaves the rate where it was does
    /// nothing, so a bulb joining a room of three does not restart the tick.
    private func applyStreamRate() {
        let rate = streamRate
        guard rate != appliedStreamRate else { return }
        appliedStreamRate = rate
        trace?.event("ups", detail: "ceiling \(updatesPerSecond) rate \(rate) bulbs \(bulbs.count)")
        enqueueCommand { controller in
            await controller.setMaxStreamedSendsPerSecond(rate)
        }
        guard state == .running else { return }
        startTicking(at: rate)
    }

    // MARK: Internals

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func performPause(reason: String) {
        guard state == .running else { return }
        trace?.event("pause", detail: reason)
        tickSource.stop()
        pendingFrames.removeAll(keepingCapacity: true)
        setState(.paused(reason: reason))
    }

    /// Applied at the end of a transition, where `isTransitioning` is still true, so it
    /// goes straight to the work rather than back through `pause` and round in a circle.
    private func applyPendingPause() {
        guard let reason = pendingPauseReason else { return }
        pendingPauseReason = nil
        performPause(reason: reason)
    }

    private func startTicking(at rate: Int) {
        tickSource.start(ticksPerSecond: rate) { [weak self] in
            self?.tick()
        }
    }

    /// Runs `work` after every command already queued. Keeps sends in the order they
    /// were computed without making every caller asynchronous.
    private func enqueueCommand(_ work: @escaping @Sendable (BulbController) async -> Void) {
        let previous = sendChain
        sendChain = Task { [controller] in
            await previous?.value
            await work(controller)
        }
    }

    /// Starts the two reading tasks, once per engine. Both live until `deinit`: see the
    /// note in `stop` for why they must never be canceled to pause the flow.
    private func startObserving() {
        if frameTask == nil {
            frameTask = Task { [weak self, frameSource] in
                for await frame in frameSource.frames {
                    await MainActor.run {
                        self?.enqueue(frame)
                    }
                }
            }
        }
        if permissionTask == nil {
            permissionTask = Task { [weak self, frameSource] in
                for await update in frameSource.permissionUpdates {
                    await MainActor.run {
                        self?.applyPermission(update)
                    }
                }
            }
        }
    }

    private func applyPermission(_ update: AudioTapPermission) {
        guard permission != update else { return }
        permission = update
        trace?.event("permission", detail: "\(update)")
        onPermissionChange?(update)
    }

    private func enqueue(_ frame: AudioTap.AudioFrame) {
        // The reader outlives any one session, so anything arriving while the engine is
        // off or paused is dropped here rather than by stopping the reader.
        guard state == .running else { return }
        pendingFrames.append(frame)
        if pendingFrames.count > Self.maximumPendingFrames {
            pendingFrames.removeFirst(pendingFrames.count - Self.maximumPendingFrames)
        }
    }

    private func tick() {
        guard state == .running else { return }
        let traceStart = trace == nil ? 0 : ProcessInfo.processInfo.systemUptime

        let frames = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)

        var beats: [BeatEvent] = []
        for frame in frames {
            let converted = FrameBridge.effectsFrame(from: autoGain.normalize(frame))
            beats.append(contentsOf: detector.process(converted))
            // The detector keeps seeing every frame even while the gate is shut, so its
            // rolling window is warm the moment the music comes back in.
            let elapsed = lastGatedFrameTime.map { max(0, converted.time - $0) } ?? 0
            lastGatedFrameTime = converted.time
            gate.update(rms: converted.rms, elapsed: elapsed)
            latestFrame = converted
        }

        guard let frame = latestFrame else { return }
        // The meter publishes the gate's own smoothed level, not the raw frame RMS. The
        // marker the user drags has to sit on the same scale the gate compares against,
        // or a bar bouncing past a marker would mean nothing about whether the gate is
        // open. It also happens to read better: raw RMS at ten frames a second flickers.
        if level != gate.loudness {
            level = gate.loudness
            onLevelChange?(level)
        }

        // One timestamp for the whole tick. The rate limiter lives behind an actor, so
        // stamping the time in there would measure the hop rather than the tick.
        let tickTime = Date()
        let now = ProcessInfo.processInfo.systemUptime
        // Below the gate the room is quiet, so the effect is ticked with no beats at all
        // rather than having its output painted over: the palette must not walk on while
        // nobody can see it. The effect is still ticked, so its own decay keeps running
        // and it does not come back holding a color from before the quiet passage.
        let isOpen = gate.isOpen
        let asked = effect.tick(beats: isOpen ? beats : [],
                                frame: frame,
                                bulbCount: bulbs.count,
                                palette: palette,
                                time: now)
        // Below the gate every bulb heads for calm, so the room rests at Darkest in the
        // effect's own color rather than going black. It glides there over the Fade
        // rather than landing in one tick: a gate that shuts mid hit used to drop the room
        // from Brightest to Darkest in a single send.
        let outputs = glide.apply(asked, isOpen: isOpen, release: timing.release, time: now)
        // The effect reports a hue and how hard it is hitting; the range the user set
        // turns that into a brightness.
        let output = outputs.map { entry in
            entry.rendered(floor: brightnessFloor, ceiling: brightnessCeiling)
        }

        // `shouldSend` records the color as sent, so a send that never reached the wire
        // would have to be undone with `deduper.forget(bulb.id)`. `BulbController` reports
        // no per send failure: an unencodable message is logged and dropped inside the
        // actor, and UDP has no delivery signal at all. The next visibly different color
        // sends anyway, so there is nothing to undo here.
        var toSend: [(bulb: Bulb, color: GoveeRGB)] = []
        for (index, bulb) in bulbs.enumerated() where index < output.count {
            guard deduper.shouldSend(output[index], for: bulb.id) else { continue }
            toSend.append((bulb, FrameBridge.goveeColor(from: output[index])))
        }

        let sends = toSend
        let targets = bulbs
        guard let trace else {
            enqueueCommand { controller in
                await Self.stream(sends, across: targets, at: tickTime, through: controller)
                await controller.flushStreamed(bulbs: targets, at: tickTime)
            }
            return
        }

        // Tracing: the same sends in the same order, with each one's fate handed to the
        // trace once the controller has decided it.
        let row = PartyTraceSession.Tick(
            wall: tickTime,
            uptime: traceStart,
            dtMilliseconds: lastTraceTickUptime.map { (traceStart - $0) * 1000 },
            workMilliseconds: (ProcessInfo.processInfo.systemUptime - traceStart) * 1000,
            frames: frames.count,
            loudness: gate.loudness,
            isOpen: isOpen,
            lowBeats: beats.filter { $0.band == .subBass || $0.band == .bass }.count,
            beats: beats.count,
            bulbIDs: targets.map(\.id),
            intensities: outputs.map(\.intensity),
            colors: output.map(FrameBridge.goveeColor(from:)),
            submitted: Set(sends.map(\.bulb.id)))
        lastTraceTickUptime = traceStart
        enqueueCommand { controller in
            let wired = await Self.stream(sends, across: targets, at: tickTime, through: controller)
            let released = await controller.flushStreamed(bulbs: targets, at: tickTime)
            trace.recordTick(row, wired: wired, released: released)
        }
    }

    /// One tick's colors, each bulb at its own slot a little way into the tick rather
    /// than all of them in one burst: about twenty milliseconds across the room, in the
    /// room's order (`StreamRateLimiter.sendOffset`). A bulb's slot is its place in the
    /// room, not its place among the bulbs that happen to send, so its own sends stay one
    /// tick apart whatever the deduper skipped.
    ///
    /// Only ever inside one tick, and on the one serial command chain: every bulb still
    /// gets this tick's color before any bulb gets the next tick's. Spreading bulbs across
    /// ticks instead made them visibly disagree (smoothness investigation, fix 1).
    ///
    /// Every color keeps the tick's own timestamp, so the rate limiter judges the tick,
    /// not the slot. Returns the ids that went on the wire, for the trace.
    @discardableResult
    private nonisolated static func stream(_ sends: [(bulb: Bulb, color: GoveeRGB)],
                                           across room: [Bulb],
                                           at tickTime: Date,
                                           through controller: BulbController) async -> Set<String> {
        let slots = Dictionary(room.enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        // A sleep that wakes late would otherwise leave every later slot already passed,
        // and those bulbs would go out in exactly the burst this is here to break up. So
        // no two sends are ever closer than half a slot, even behind a late wake.
        let minimumGap = StreamRateLimiter.sendOffset(forSlot: 1, of: room.count) / 2
        let clock = ContinuousClock()
        let start = clock.now
        var earliest = start
        var wired = Set<String>()
        for entry in sends {
            let slot = start.advanced(by: .seconds(
                StreamRateLimiter.sendOffset(forSlot: slots[entry.bulb.id] ?? 0, of: room.count)))
            let target = max(slot, earliest)
            if target > clock.now {
                try? await Task.sleep(until: target, tolerance: .microseconds(250), clock: clock)
            }
            if await controller.streamColor(entry.color, to: entry.bulb, at: tickTime) {
                wired.insert(entry.bulb.id)
            }
            earliest = clock.now.advanced(by: .seconds(minimumGap))
        }
        return wired
    }

    // MARK: The opt-in trace

    /// Whether this session is being traced. Read by the tests.
    var isTracing: Bool {
        trace != nil
    }

    /// The running trace's file. Read by the tests.
    var traceFileURL: URL? {
        trace?.fileURL
    }

    /// Opens a trace when the defaults key asks for one. The observers go on through the
    /// command chain, so they are in place before the first tick's colors are sent.
    private func beginTrace() {
        guard let factory = traceFactory,
              let session = factory.makeSession(bulbs: bulbs, settings: traceSettings()) else { return }
        trace = session
        lastTraceTickUptime = nil
        enqueueCommand { controller in
            await session.attach(to: controller)
        }
    }

    /// Logs the stop at once, then lets the trace listen a little longer before it closes,
    /// so the settle color and whatever the light mode sends next are in the file too.
    private func endTrace(reason: String) {
        guard let session = trace else { return }
        trace = nil
        lastTraceTickUptime = nil
        session.finish(reason: reason, controller: controller)
    }

    private func traceSettings() -> String {
        String(format: "effect %@ palette %@ marker %.3f always %d gate %.3f sensitivity %.3f "
               + "attack_s %.3f release_s %.3f floor %.3f ceiling %.3f ups %d rate %d bulbs %d",
               effect.kind.rawValue, palette.id, gateMarker, alwaysReacts ? 1 : 0,
               gate.threshold, detector.sensitivity, timing.attack, timing.release,
               brightnessFloor, brightnessCeiling, updatesPerSecond, appliedStreamRate, bulbs.count)
    }
}
