import Foundation

/// A value moving from one number to another over wall clock time.
///
/// Wall clock, and only wall clock. Every other clock in Glowbeat is monotonic:
/// `TickSource` schedules on `DispatchTime.now()` and `SceneEngine` runs on
/// `ProcessInfo.systemUptime`, both of which stop while the Mac is asleep. That is right
/// for a ten per second party tick and wrong for a thirty minute sunrise: a ramp armed
/// at 06:30 has to be where it should be when the lid opens at 07:10, not ten minutes
/// into a ramp it only just started counting. So a ramp holds the `Date` it began at and
/// every step asks it for its value at the `Date` it is being asked about.
/// Research: `docs/research/sleep-wake-nightshift-research.md` section C1.
struct LightRamp: Equatable, Sendable {

    /// The moment the ramp is measured from, which is the timer's own time rather than
    /// the moment the app noticed the timer. A tick that lands twenty seconds late lands
    /// twenty seconds along the ramp instead of restarting it.
    let start: Date
    /// Seconds. Zero means the ramp is over the moment it begins, which is what a ramp
    /// length of zero minutes means on screen.
    let duration: TimeInterval
    let from: Double
    let to: Double

    init(start: Date, duration: TimeInterval, from: Double, to: Double) {
        self.start = start
        self.duration = max(0, duration)
        self.from = from
        self.to = to
    }

    var end: Date {
        start.addingTimeInterval(duration)
    }

    /// 0 through 1. A ramp with no duration is finished as soon as it starts.
    func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(start)
        return min(1, max(0, elapsed / duration))
    }

    func value(at now: Date) -> Double {
        from + (to - from) * progress(at: now)
    }

    func isFinished(at now: Date) -> Bool {
        progress(at: now) >= 1
    }
}
