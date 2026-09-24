import Foundation
@testable import Glowbeat

/// A tick source the test drives by hand, so engine behavior is deterministic.
@MainActor
final class ManualTickSource: TickSource {
    private(set) var ticksPerSecond = 0
    private(set) var isRunning = false
    private var handler: (@MainActor () -> Void)?

    func start(ticksPerSecond: Int, handler: @escaping @MainActor () -> Void) {
        self.ticksPerSecond = ticksPerSecond
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
