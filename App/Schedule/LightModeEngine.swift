import Foundation
import GoveeLAN
import OSLog

/// Decides what white the room should be, and sends it.
///
/// It is not a renderer. Party Mode and the scenes tick and paint; this one holds a
/// single number and only sends when that number changes, so a color the user picked by
/// hand, in Glowbeat or on their phone, stands until the next real transition. The
/// number changes at exactly three moments: the user picks a mode, Auto steps through a
/// shift, and a wake ramp ends (which `ScheduleEngine` asks for).
///
/// Auto follows the Mac. Night Shift's own `enabled` flag is the state, and when Night
/// Shift has no schedule and nobody has switched it on by hand, sunrise and sunset are,
/// so Auto is never a control that does nothing. Neither reading is required: with both
/// gone, Auto sits on Daylight and says so.
@MainActor
final class LightModeEngine {

    struct Status: Equatable, Sendable {

        /// What the current answer is being read from.
        enum Origin: Equatable, Sendable {
            /// Daylight or Night: the user set the temperature outright.
            case fixed
            /// Auto, following Night Shift's own flag.
            case nightShift
            /// Auto, following sunrise and sunset, because Night Shift has no schedule
            /// and is not switched on by hand, or because it could not be read.
            case sun
            /// Auto with nothing to follow: neither Night Shift nor the sun times
            /// answered, so Auto rests on Daylight.
            case unavailable
        }

        var mode: LightMode
        var origin: Origin
        /// Whether the room should be on the warm white rather than the cool one.
        var isWarm: Bool
        /// The temperature right now, part way along a shift if one is running.
        var kelvin: Int
        /// When the current state turns over, where that is knowable. Nil for a fixed
        /// mode, for a Night Shift switched on by hand, and where nothing answered.
        var nextChange: Date?
        /// True while a shift between the two whites is part way through.
        var isShifting: Bool
    }

    private(set) var status: Status
    var onStatusChange: (@MainActor (Status) -> Void)?

    /// The temperature the engine believes the room is on. A wake reads this: bulbs come
    /// up in the white the light mode is already holding rather than in a second one.
    private(set) var kelvin: Int

    private let controller: BulbController
    private let source: (any NightShiftSource)?
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "LightMode")

    private var mode: LightMode
    private var shiftLength: TimeInterval
    private var bulbs: [Bulb] = []
    private var shift: LightRamp?
    /// What the last reconcile resolved to. Nil until the first one, which is what makes
    /// the first look an adoption rather than a transition: launching Glowbeat must never
    /// repaint a room nobody asked it to repaint.
    private var lastResolution: Resolution?
    /// True when a change was worked out while Party Mode, a scene or a schedule ramp
    /// owned the bulbs. It is the only thing that gets re-applied when they let go.
    private var missedApply = false
    private var isSuspended = false
    private var sendChain: Task<Void, Never>?

    private struct Resolution: Equatable {
        var origin: Status.Origin
        var isWarm: Bool
        /// When this state began, where that is knowable. A shift is measured from here
        /// rather than from the moment the app noticed, so a transition missed while the
        /// Mac slept lands already finished instead of starting a fresh half hour ramp.
        var since: Date?
        var until: Date?
    }

    init(controller: BulbController,
         source: (any NightShiftSource)?,
         mode: LightMode = GlowbeatSettings.defaults.lightMode,
         shiftLengthMinutes: Int = GlowbeatSettings.defaultShiftLengthMinutes,
         calendar: Calendar = .current) {
        self.controller = controller
        self.source = source
        self.mode = mode
        self.shiftLength = TimeInterval(GlowbeatSettings.clampedShiftLengthMinutes(shiftLengthMinutes)) * 60
        self.calendar = calendar
        self.kelvin = mode.fixedKelvin ?? WhiteTemperature.daylightKelvin
        self.status = Status(mode: mode,
                             origin: mode == .auto ? .unavailable : .fixed,
                             isWarm: mode == .night,
                             kelvin: self.kelvin,
                             nextChange: nil,
                             isShifting: false)
    }

    deinit {
        // The chain is deliberately left alone, the way `SceneEngine` leaves its own: a
        // temperature already queued has to reach the bulbs even if the engine goes away.
    }

    // MARK: Lifecycle

    func startObserving() {
        source?.onChange = { [weak self] in
            self?.handleNightShiftNotification()
        }
        source?.startObserving()
    }

    func stopObserving() {
        source?.stopObserving()
    }

    // MARK: The mode

    /// A deliberate choice, so it lands at once rather than over a shift. The shift
    /// length is for Auto following the Mac in the background, not for a click.
    func setMode(_ newMode: LightMode, at now: Date) {
        guard newMode != mode else { return }
        mode = newMode
        shift = nil
        let resolution = resolve(at: now)
        lastResolution = resolution
        apply(kelvin: targetKelvin(for: resolution), force: true)
        publish(resolution, at: now)
    }

    /// Takes effect on the next transition. A shift already running keeps the length it
    /// began with: changing a ramp under itself would make the room jump.
    func setShiftLength(minutes: Int) {
        shiftLength = TimeInterval(GlowbeatSettings.clampedShiftLengthMinutes(minutes)) * 60
    }

    func updateBulbs(_ bulbs: [Bulb]) {
        let wasEmpty = self.bulbs.isEmpty
        self.bulbs = bulbs
        // A transition worked out while nothing was on the network is not lost: the
        // bulbs on a scheduled switch come back some minutes after the Mac does, and the
        // room should be the white the app decided on, not the white it was cut at.
        if wasEmpty, !bulbs.isEmpty, missedApply {
            flushMissedApply()
        }
    }

    /// Party Mode, a scene and a schedule ramp all own the bulbs while they run. The mode
    /// never writes over them; it remembers that it wanted to and applies once they stop.
    ///
    /// `predecessor` is whatever the one letting go still has on its way to the bulbs:
    /// Party Mode's last tick and the flush behind it. The white waits for it, on this
    /// engine's own chain, so it lands after them rather than racing them from a second
    /// chain, which is how a stopped Party Mode used to leave the room on its dim base
    /// instead of the white (smoothness investigation H3, 2026-09-23).
    func setSuspended(_ suspended: Bool, after predecessor: Task<Void, Never>? = nil) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if !suspended {
            flushMissedApply(after: predecessor)
        }
    }

    /// Whether a white is waiting to go out the moment whatever owns the bulbs lets go: a
    /// transition worked out, or a mode picked, while Party Mode, a scene or a ramp held
    /// them. Party Mode reads this as it stops, because when it is true the light mode is
    /// about to paint the room and a settle color would only flash first.
    var hasPendingApply: Bool {
        missedApply && !bulbs.isEmpty
    }

    /// The user put a color on the room by hand, so the white this engine is holding is
    /// no longer what is up there.
    ///
    /// It keeps its number and waits for the next real transition rather than arguing,
    /// which is the rule the schedule brief set for a color picked in Glowbeat or on a
    /// phone. What this clears is the one thing that would otherwise reach the bulbs
    /// unasked: a transition worked out while Party Mode, a scene or a ramp owned them,
    /// which is flushed the moment they let go.
    func userPickedAColor() {
        missedApply = false
    }

    // MARK: Reconciling

    /// The one question, asked on every tick: given the clock right now, what white
    /// should the room be? Sends only when the answer moved.
    func reconcile(at now: Date) {
        let resolution = resolve(at: now)
        defer { publish(resolution, at: now) }

        guard let previous = lastResolution else {
            // The first look of the launch. Adopt the answer without painting the room:
            // opening Glowbeat is not a request to change anything.
            lastResolution = resolution
            kelvin = targetKelvin(for: resolution)
            return
        }
        lastResolution = resolution

        guard mode == .auto else {
            shift = nil
            return
        }
        if resolution.isWarm != previous.isWarm {
            beginShift(to: resolution, at: now)
        }
        advanceShift(at: now)
    }

    private func handleNightShiftNotification() {
        // The callback fires once per mutation rather than once per logical change, so
        // it is only ever a hint to look again; `reconcile` decides whether anything
        // actually moved.
        reconcile(at: Date())
    }

    private func beginShift(to resolution: Resolution, at now: Date) {
        let start = resolution.since ?? now
        shift = LightRamp(start: start,
                          duration: shiftLength,
                          from: Double(kelvin),
                          to: Double(targetKelvin(for: resolution)))
    }

    private func advanceShift(at now: Date) {
        guard let shift else { return }
        let value = WhiteTemperature.clamped(shift.value(at: now))
        if shift.isFinished(at: now) {
            self.shift = nil
        }
        apply(kelvin: value, force: false)
    }

    // MARK: Resolution

    private func targetKelvin(for resolution: Resolution) -> Int {
        resolution.isWarm ? WhiteTemperature.nightKelvin : WhiteTemperature.daylightKelvin
    }

    private func resolve(at now: Date) -> Resolution {
        guard mode == .auto else {
            return Resolution(origin: .fixed, isWarm: mode == .night, since: nil, until: nil)
        }
        let status = source?.readStatus()
        let sun = source?.readSunSchedule()

        guard let status else {
            // The private API did not answer, which is the sandbox case and the "Apple
            // removed it" case both. Fall back to the sun, and to Daylight after that.
            return sunResolution(sun, at: now)
                ?? Resolution(origin: .unavailable, isWarm: false, since: nil, until: nil)
        }
        // No schedule and not switched on by hand means Night Shift is doing nothing all
        // day, and following it would make Auto a control that never changes anything.
        if status.rawMode == NightShiftStatus.Mode.none.rawValue, !status.isEnabled {
            return sunResolution(sun, at: now)
                ?? Resolution(origin: .nightShift, isWarm: false, since: nil, until: nil)
        }
        let edge = derivedEdge(for: status, sun: sun, at: now)
        return Resolution(origin: .nightShift,
                          isWarm: status.isEnabled,
                          since: edge?.since,
                          until: edge?.until)
    }

    private func sunResolution(_ sun: SunSchedule?, at now: Date) -> Resolution? {
        guard let phase = sun?.phase(at: now) else { return nil }
        return Resolution(origin: .sun,
                          isWarm: phase.isNight,
                          since: phase.since,
                          until: phase.until)
    }

    /// When the current Night Shift state began and ends, worked out from its schedule.
    ///
    /// The schedule only dates the edge; `enabled` is still what says warm or cool. If
    /// the two disagree, which is what a manual toggle part way through a window looks
    /// like, the edge is dropped rather than trusted, and the shift is measured from the
    /// moment Glowbeat noticed instead.
    private func derivedEdge(for status: NightShiftStatus,
                             sun: SunSchedule?,
                             at now: Date) -> (since: Date, until: Date)? {
        switch status.mode {
        case .sunsetToSunrise:
            guard let phase = sun?.phase(at: now), phase.isNight == status.isEnabled else {
                return nil
            }
            return (phase.since, phase.until)
        case .custom:
            let schedule = status.schedule
            guard schedule.from != schedule.to else { return nil }
            let lastFrom = schedule.from.mostRecentOccurrence(onOrBefore: now, calendar: calendar)
            let lastTo = schedule.to.mostRecentOccurrence(onOrBefore: now, calendar: calendar)
            let isWarm = lastFrom > lastTo
            guard isWarm == status.isEnabled else { return nil }
            let since = max(lastFrom, lastTo)
            let until = isWarm
                ? schedule.to.nextOccurrence(after: now, calendar: calendar)
                : schedule.from.nextOccurrence(after: now, calendar: calendar)
            return (since, until)
        case .some(.none), nil:
            return nil
        }
    }

    // MARK: Sending

    private func apply(kelvin newKelvin: Int, force: Bool) {
        let clamped = WhiteTemperature.clamped(newKelvin)
        guard force || clamped != kelvin else { return }
        kelvin = clamped
        guard !isSuspended, !bulbs.isEmpty else {
            missedApply = true
            return
        }
        missedApply = false
        send(clamped)
    }

    private func flushMissedApply(after predecessor: Task<Void, Never>? = nil) {
        guard missedApply, !isSuspended, !bulbs.isEmpty else { return }
        missedApply = false
        send(kelvin, after: predecessor)
    }

    /// Queued on this engine's own chain, so every later step of a shift still lands after
    /// it, and, when something is handed over, only once that has gone out too.
    private func send(_ value: Int, after predecessor: Task<Void, Never>? = nil) {
        let targets = bulbs
        logger.log("Light mode setting the room to \(value, privacy: .public) K.")
        enqueueCommand { controller in
            await predecessor?.value
            await controller.setColorTemperature(kelvin: value, bulbs: targets)
        }
    }

    /// Runs `work` after every command already queued, so two steps of a shift can never
    /// land out of order. The same serial chain `SceneEngine` uses, for the same reason.
    private func enqueueCommand(_ work: @escaping @Sendable (BulbController) async -> Void) {
        let previous = sendChain
        sendChain = Task { [controller] in
            await previous?.value
            await work(controller)
        }
    }

    // MARK: Status

    private func publish(_ resolution: Resolution, at now: Date) {
        let newStatus = Status(mode: mode,
                               origin: resolution.origin,
                               isWarm: resolution.isWarm,
                               kelvin: kelvin,
                               nextChange: resolution.until,
                               isShifting: shift?.isFinished(at: now) == false)
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
