import Foundation
import GoveeLAN
import OSLog

/// The wake and sleep timers.
///
/// There is no long timer anywhere in here, and that is the whole design. A dispatch
/// timer armed for "in nine hours" counts awake time only, so on a laptop that sleeps
/// every night it fires days late. Instead a short timer asks one question every thirty
/// seconds: given the wall clock right now, is there a wake or sleep time between the
/// last time I looked and this moment? The same question is asked again at launch and
/// whenever the Mac wakes, so a timer that came due behind a closed lid is caught the
/// moment the lid opens. Research: `docs/research/sleep-wake-nightshift-research.md`
/// sections C1 to C3.
///
/// A timer that is on time runs its ramp. A timer that is being caught up on skips the
/// ramp and applies the state that should be in force, because replaying a half hour
/// sunrise at nine in the morning helps nobody.
@MainActor
final class ScheduleEngine {

    enum State: Equatable {
        case idle
        /// A brightness ramp up to the wake brightness.
        case waking(LightRamp)
        /// A brightness ramp down to one percent, which ends with the bulbs off.
        case sleeping(LightRamp)

        var isRunning: Bool {
            self != .idle
        }

        var ramp: LightRamp? {
            switch self {
            case .idle: return nil
            case .waking(let ramp), .sleeping(let ramp): return ramp
            }
        }
    }

    struct Event: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case wake
            case sleep
        }

        var kind: Kind
        var date: Date
    }

    private(set) var state: State = .idle
    var onStateChange: (@MainActor (State) -> Void)?

    /// Run at the top of every tick, before the schedule reconciles, so the light mode
    /// settles first and a wake turns the bulbs on in the white that is actually in force.
    var onTick: (@MainActor (Date) -> Void)?
    /// Called before a sleep timer runs. Sleep always wins: it stops Party Mode and any
    /// scene, and then dims. Phil's call, 2026-09-16.
    var willRunSleep: (@MainActor () -> Void)?
    /// Whether Party Mode or a scene owns the bulbs. A wake timer is skipped for the day
    /// when this is true, rather than interrupting music the user is listening to.
    var isBusy: (@MainActor () -> Bool)?
    /// The white the light mode is holding, which is what a wake turns the bulbs on at.
    var currentKelvin: (@MainActor () -> Int)?

    /// Thirty seconds. Short enough that a timer is never noticeably late, long enough to
    /// be free on a laptop.
    static let tickInterval: TimeInterval = 30
    /// How late a timer may be and still count as on time, and so still run its ramp.
    /// One tick plus a minute of slack, so a busy Mac never turns a ramp into a jump.
    static let onTimeTolerance: TimeInterval = 90
    /// How old a missed timer may be and still be caught up on. Twelve hours covers the
    /// case the feature exists for, a wake timer that came due behind a closed lid
    /// overnight, and stops a Mac that was shut for a week from lighting the room at
    /// three in the afternoon because this morning's wake time is technically unhandled.
    static let maximumCatchUp: TimeInterval = 12 * 60 * 60
    /// How long an end state is held for bulbs that are not on the network yet. The bulb
    /// string is on a scheduled smart switch and comes back some minutes after the Mac
    /// does; a wake sent into an empty network reaches nothing and there is no error to
    /// catch. Research section D4.
    static let reachabilityGrace: TimeInterval = 5 * 60
    /// Where a wake starts and a sleep ends. One percent rather than zero, because zero
    /// is what the bulb reports when it is off.
    static let edgeBrightness = 1

    private let controller: BulbController
    private let ticker: any IntervalTickSource
    private let store: SettingsStore
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "Schedule")

    private var settings: ScheduleSettings
    private var bulbs: [Bulb] = []
    private var sendChain: Task<Void, Never>?
    /// The last brightness put on the wire by a ramp, so a ramp holding a value costs no
    /// traffic. Nil between ramps.
    private var lastSentBrightness: Int?
    /// An end state that had nowhere to go, and the moment it stops being worth applying.
    private var pendingEndState: (event: Event, expiry: Date)?

    init(controller: BulbController,
         ticker: any IntervalTickSource,
         store: SettingsStore,
         settings: ScheduleSettings = .defaults,
         clock: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.controller = controller
        self.ticker = ticker
        self.store = store
        self.settings = settings
        self.clock = clock
        self.calendar = calendar
    }

    deinit {
        // The chain is left alone on purpose, the way `SceneEngine` leaves its own: the
        // lights out at the end of a sleep ramp has to reach the bulbs regardless.
    }

    // MARK: Lifecycle

    func start() {
        ticker.start(interval: Self.tickInterval) { [weak self] in
            self?.reconcileNow()
        }
        reconcileNow()
    }

    func stop() {
        ticker.stop()
        cancelRamp()
    }

    /// The Mac woke, or the app just launched, or thirty seconds went by.
    func reconcileNow() {
        reconcile(at: clock())
    }

    // MARK: Settings and bulbs

    func setSettings(_ newSettings: ScheduleSettings) {
        let wasEnabled = settings.isEnabled
        settings = newSettings
        if wasEnabled, !newSettings.isEnabled {
            cancelRamp()
        }
        if !wasEnabled, newSettings.isEnabled {
            // Turning the schedule on is not a request to catch up on everything that
            // happened while it was off, so the window starts here.
            store.saveLastReconciled(clock())
        }
    }

    func updateBulbs(_ newBulbs: [Bulb]) {
        let wasEmpty = bulbs.isEmpty
        bulbs = newBulbs
        guard wasEmpty, !newBulbs.isEmpty else { return }
        flushPendingEndState(at: clock())
    }

    /// Stops a ramp part way through and leaves the room where it is.
    ///
    /// Party Mode and the scenes win against a ramp the way they win against each other,
    /// and so does the user reaching for the power switch on the All row: whoever touched
    /// the bulbs last meant it.
    func cancelRamp() {
        guard state.isRunning else { return }
        logger.log("A schedule ramp was stopped part way through.")
        lastSentBrightness = nil
        setState(.idle)
    }

    // MARK: The next event, for the UI

    func nextEvent(at now: Date) -> Event? {
        guard settings.isEnabled else { return nil }
        let wake = settings.wakeTime.nextOccurrence(after: now, calendar: calendar)
        let sleep = settings.sleepTime.nextOccurrence(after: now, calendar: calendar)
        return wake <= sleep ? Event(kind: .wake, date: wake) : Event(kind: .sleep, date: sleep)
    }

    // MARK: Reconciling

    func reconcile(at now: Date) {
        onTick?(now)

        guard settings.isEnabled else {
            cancelRamp()
            pendingEndState = nil
            store.saveLastReconciled(now)
            return
        }

        let last = store.loadLastReconciled()
        store.saveLastReconciled(now)
        expirePendingEndState(at: now)

        // No window yet means this is the first launch that has ever looked, so there is
        // nothing behind us to catch up on.
        guard let last, last < now else {
            advance(at: now)
            return
        }

        if let event = firedEvent(since: last, at: now) {
            run(event, at: now)
        } else {
            advance(at: now)
        }
    }

    /// The most recent wake or sleep time inside `(last, now]`, or nil.
    ///
    /// Only the most recent one matters. A Mac that was asleep for two days crossed both
    /// timers several times, and replaying them in order would walk the room through
    /// every one of them; the last one is the state that should be in force.
    private func firedEvent(since last: Date, at now: Date) -> Event? {
        let wake = settings.wakeTime.mostRecentOccurrence(onOrBefore: now, calendar: calendar)
        let sleep = settings.sleepTime.mostRecentOccurrence(onOrBefore: now, calendar: calendar)
        var candidates: [Event] = []
        if wake > last {
            candidates.append(Event(kind: .wake, date: wake))
        }
        if sleep > last {
            candidates.append(Event(kind: .sleep, date: sleep))
        }
        guard let fired = candidates.max(by: { $0.date < $1.date }),
              now.timeIntervalSince(fired.date) <= Self.maximumCatchUp else {
            return nil
        }
        return fired
    }

    private func run(_ event: Event, at now: Date) {
        let isOnTime = now.timeIntervalSince(event.date) <= Self.onTimeTolerance
        switch event.kind {
        case .wake:
            guard !(isBusy?() ?? false) else {
                logger.log("Wake skipped: Party Mode or a scene is running.")
                return
            }
            runWake(event, at: now, withRamp: isOnTime)
        case .sleep:
            // Always, and before anything else: sleep wins against Party Mode and any
            // scene, and both have to let go of the bulbs before a ramp can drive them.
            willRunSleep?()
            runSleep(event, at: now, withRamp: isOnTime)
        }
    }

    private func runWake(_ event: Event, at now: Date, withRamp: Bool) {
        guard hasBulbs(orHold: event, at: now) else { return }
        let kelvin = currentKelvin?() ?? WhiteTemperature.daylightKelvin
        let top = settings.wakeBrightness
        let duration = withRamp ? settings.wakeRamp : 0
        guard duration > 0 else {
            logger.log("Wake applied in one step.")
            push(power: true, kelvin: kelvin, brightness: top)
            lastSentBrightness = nil
            setState(.idle)
            return
        }
        push(power: true, kelvin: kelvin, brightness: Self.edgeBrightness)
        lastSentBrightness = Self.edgeBrightness
        setState(.waking(LightRamp(start: event.date,
                                   duration: duration,
                                   from: Double(Self.edgeBrightness),
                                   to: Double(top))))
        advance(at: now)
    }

    private func runSleep(_ event: Event, at now: Date, withRamp: Bool) {
        guard hasBulbs(orHold: event, at: now) else { return }
        let duration = withRamp ? settings.sleepRamp : 0
        guard duration > 0 else {
            logger.log("Sleep applied in one step.")
            push(power: false, kelvin: nil, brightness: nil)
            lastSentBrightness = nil
            setState(.idle)
            return
        }
        setState(.sleeping(LightRamp(start: event.date,
                                     duration: duration,
                                     from: Double(startingBrightness()),
                                     to: Double(Self.edgeBrightness))))
        lastSentBrightness = nil
        advance(at: now)
    }

    /// Where a sleep ramp starts: the brightest bulb the app has a report for, or full
    /// brightness where it has none. Starting anywhere above the room's real level would
    /// make the lights jump up before they went down.
    private func startingBrightness() -> Int {
        let reported = bulbs.compactMap { $0.state?.brightness }.max()
        return min(100, max(Self.edgeBrightness, reported ?? 100))
    }

    /// Moves a ramp on by one step, and ends it when the clock says it is over.
    private func advance(at now: Date) {
        switch state {
        case .idle:
            return
        case .waking(let ramp):
            sendBrightness(Int(ramp.value(at: now).rounded()))
            guard ramp.isFinished(at: now) else { return }
            // The mode applies again at the end of a wake, so a room that came up before
            // an Auto transition ends on the white that transition asked for.
            if let kelvin = currentKelvin?() {
                sendTemperature(kelvin)
            }
            lastSentBrightness = nil
            setState(.idle)
        case .sleeping(let ramp):
            sendBrightness(Int(ramp.value(at: now).rounded()))
            guard ramp.isFinished(at: now) else { return }
            push(power: false, kelvin: nil, brightness: nil)
            lastSentBrightness = nil
            setState(.idle)
        }
    }

    // MARK: Bulbs that are not there yet

    private func hasBulbs(orHold event: Event, at now: Date) -> Bool {
        guard bulbs.isEmpty else { return true }
        logger.log("A schedule timer fired with no bulbs on the network; holding its end state.")
        pendingEndState = (event, now.addingTimeInterval(Self.reachabilityGrace))
        return false
    }

    private func expirePendingEndState(at now: Date) {
        guard let pending = pendingEndState, now >= pending.expiry else { return }
        pendingEndState = nil
    }

    /// Applies a held end state now that there is something to apply it to. Never a ramp:
    /// the timer is already minutes old by the time the bulbs answer.
    private func flushPendingEndState(at now: Date) {
        guard let pending = pendingEndState, now < pending.expiry else {
            pendingEndState = nil
            return
        }
        pendingEndState = nil
        switch pending.event.kind {
        case .wake:
            guard !(isBusy?() ?? false) else { return }
            push(power: true,
                 kelvin: currentKelvin?() ?? WhiteTemperature.daylightKelvin,
                 brightness: settings.wakeBrightness)
        case .sleep:
            willRunSleep?()
            push(power: false, kelvin: nil, brightness: nil)
        }
    }

    // MARK: Sending

    private func sendBrightness(_ value: Int) {
        let clamped = min(100, max(0, value))
        guard clamped != lastSentBrightness else { return }
        lastSentBrightness = clamped
        let targets = bulbs
        guard !targets.isEmpty else { return }
        enqueueCommand { controller in
            await controller.setBrightness(clamped, bulbs: targets)
        }
    }

    private func sendTemperature(_ kelvin: Int) {
        let clamped = WhiteTemperature.clamped(kelvin)
        let targets = bulbs
        guard !targets.isEmpty else { return }
        enqueueCommand { controller in
            await controller.setColorTemperature(kelvin: clamped, bulbs: targets)
        }
    }

    /// One step of the room, in the order a bulb has to hear it: power first, then the
    /// white, then how bright. Everything goes down the one serial chain, so the lights
    /// out at the end of a sleep ramp is always the last thing a bulb hears.
    private func push(power: Bool, kelvin: Int?, brightness: Int?) {
        let targets = bulbs
        guard !targets.isEmpty else { return }
        let temperature = kelvin.map(WhiteTemperature.clamped)
        let level = brightness.map { min(100, max(0, $0)) }
        enqueueCommand { controller in
            await controller.turn(power, bulbs: targets)
            if let temperature {
                await controller.setColorTemperature(kelvin: temperature, bulbs: targets)
            }
            if let level {
                await controller.setBrightness(level, bulbs: targets)
            }
        }
    }

    private func enqueueCommand(_ work: @escaping @Sendable (BulbController) async -> Void) {
        let previous = sendChain
        sendChain = Task { [controller] in
            await previous?.value
            await work(controller)
        }
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
