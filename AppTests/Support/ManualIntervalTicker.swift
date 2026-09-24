import Foundation
@testable import Glowbeat

/// An interval tick source the test drives by hand, so a thirty second poll costs no
/// time at all. The sibling of `ManualTickSource`.
@MainActor
final class ManualIntervalTicker: IntervalTickSource {
    private(set) var interval: TimeInterval = 0
    private(set) var isRunning = false
    private var handler: (@MainActor () -> Void)?

    func start(interval: TimeInterval, handler: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.handler = handler
        isRunning = true
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    func fire(_ times: Int = 1) {
        for _ in 0..<times {
            handler?()
        }
    }
}
