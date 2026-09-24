import Foundation
@testable import Glowbeat

/// Stands in for `SMAppService.mainApp` so the suite never registers a real login item
/// on whoever's Mac happens to be running it.
///
/// It also gives the tests the one path the real service cannot be made to take on
/// demand: a `register()` that succeeds into `.requiresApproval` rather than `.enabled`,
/// which is what macOS does the first time an app asks.
@MainActor
final class FakeLoginItemService: LoginItemService {

    /// What the service reports next. Tests set this to script macOS.
    var nextStatus: LoginItemStatus = .notRegistered
    /// Thrown by the next `register()` or `unregister()`, if set.
    var errorToThrow: (any Error)?

    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var statusReads = 0

    /// What the service reports after a successful `register()`. Defaults to the honest
    /// answer for a first registration on macOS.
    var statusAfterRegister: LoginItemStatus = .requiresApproval

    init() {}

    var status: LoginItemStatus {
        statusReads += 1
        return nextStatus
    }

    func register() throws {
        registerCount += 1
        if let errorToThrow { throw errorToThrow }
        nextStatus = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let errorToThrow { throw errorToThrow }
        nextStatus = .notRegistered
    }
}
