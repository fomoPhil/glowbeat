import Foundation

/// A wall clock the test moves by hand, so an overnight schedule is provable in
/// milliseconds. The `Date` counterpart of `SceneEngineTests`' monotonic `ManualClock`.
@MainActor
final class ManualDateClock {

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: Date

        init(_ value: Date) {
            self.value = value
        }
    }

    private let box: Box

    init(_ start: Date) {
        box = Box(start)
    }

    var reader: @Sendable () -> Date {
        let box = self.box
        return {
            box.lock.lock()
            defer { box.lock.unlock() }
            return box.value
        }
    }

    var now: Date {
        reader()
    }

    func set(_ date: Date) {
        box.lock.lock()
        box.value = date
        box.lock.unlock()
    }

    func advance(by seconds: TimeInterval) {
        box.lock.lock()
        box.value = box.value.addingTimeInterval(seconds)
        box.lock.unlock()
    }
}
