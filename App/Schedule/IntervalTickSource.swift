import Foundation

/// Drives the schedule. A second seam beside `TickSource` because the two measure
/// different things: `TickSource` is told a rate in ticks per second, which cannot
/// express one tick every thirty seconds, and it exists so a ten per second party loop
/// can be stepped by hand. This one is told an interval.
@MainActor
protocol IntervalTickSource: AnyObject {
    func start(interval: TimeInterval, handler: @escaping @MainActor () -> Void)
    func stop()
}

/// The production one: a dispatch timer on the main queue.
///
/// It runs on the uptime clock, so it loses the time the Mac spends asleep and an
/// overdue tick simply fires once on wake. That is fine and deliberate: nothing here
/// decides anything from the timer. Every tick asks `ScheduleEngine` the same question
/// against `Date()`, so a tick that is late, early or missed entirely changes only when
/// the question is asked, never the answer.
@MainActor
final class TimerIntervalTickSource: IntervalTickSource {

    private var timer: DispatchSourceTimer?

    init() {}

    deinit {
        timer?.cancel()
    }

    func start(interval: TimeInterval, handler: @escaping @MainActor () -> Void) {
        stop()
        let period = max(1, interval)
        let source = DispatchSource.makeTimerSource(queue: .main)
        // A generous leeway: nothing here is time critical to the second, and letting
        // the system coalesce a thirty second timer is what keeps it off the power
        // budget of a laptop that is otherwise idle.
        source.schedule(deadline: .now() + period, repeating: period, leeway: .seconds(5))
        source.setEventHandler {
            MainActor.assumeIsolated {
                handler()
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
