import Foundation

/// Drives the Party Mode engine. Abstracted so tests can step it by hand.
@MainActor
protocol TickSource: AnyObject {
    func start(ticksPerSecond: Int, handler: @escaping @MainActor () -> Void)
    func stop()
}

/// The production tick source: a dispatch timer on the main queue.
@MainActor
final class TimerTickSource: TickSource {

    private var timer: DispatchSourceTimer?

    init() {}

    deinit {
        timer?.cancel()
    }

    func start(ticksPerSecond: Int, handler: @escaping @MainActor () -> Void) {
        stop()
        let rate = max(1, ticksPerSecond)
        let interval = 1.0 / Double(rate)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
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
