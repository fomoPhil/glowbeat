import Foundation
import ServiceManagement

/// What macOS says about the app's login item, with the one case `SMAppService` adds for
/// bundles it cannot find folded in.
///
/// Its own type rather than `SMAppService.Status` so the app can be told what the system
/// would have said. Registering a login item is a real, machine wide side effect, and a
/// test suite must never leave one behind.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// The seam over the login item. `AppModel` takes one of these instead of reaching for
/// `SMAppService.mainApp`, so the suite can script every answer macOS can give, including
/// the one the real service will not produce on demand: a registration accepted into
/// `requiresApproval`.
@MainActor
protocol LoginItemService: AnyObject {
    func register() throws
    func unregister() throws
    var status: LoginItemStatus { get }
}

/// The shipping implementation: `SMAppService.mainApp`, unchanged.
@MainActor
final class SMAppLoginItemService: LoginItemService {

    init() {}

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    var status: LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }
}

extension LoginItemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}
